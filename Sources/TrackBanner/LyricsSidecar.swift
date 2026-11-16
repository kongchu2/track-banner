import Foundation

/// 앱 번들에 들어 있는 `lyrics-sidecar`(librespot)를 자식 프로세스로 띄우고 stdin/stdout으로 이야기한다.
/// Spotify 자체 가사를 받아 오고, Spotify Connect가 알려 주는 재생 위치를 전해 준다.
/// 프로토콜은 lyrics-sidecar/src/main.rs 머리말에 있다.
@MainActor
final class LyricsSidecar {
    enum LyricsResult {
        /// color-lyrics 응답(JSON).
        case found(Data)
        /// Spotify에 가사가 없는 곡.
        case none
        /// 물어보지 못했다(로그인 안 함, 연결 중, 오류).
        case unavailable
    }

    enum LoginResult {
        case loggedIn
        case failed
        /// 다시 로그인을 시작했거나 로그아웃해서 중단됐다.
        case cancelled
    }

    /// Spotify Connect가 알린, 지금 재생 중인 것과 그 위치.
    struct Live {
        let uri: String
        let position: PlaybackPosition
    }

    /// Connect가 알리는 재생 상태가 바뀔 때마다. 재생 중이 아니거나 연결이 끊기면 nil.
    var onLive: ((Live?) -> Void)?

    /// 번들에 사이드카가 들어 있는지. Rust 없이 빌드한 앱에는 없다.
    var isAvailable: Bool { executable != nil }
    /// 저장된 로그인 정보가 있는지.
    var isLoggedIn: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("credentials.json").path) }
    /// 프로세스가 떠 있는지(연결 중 포함).
    var isRunning: Bool { process != nil }
    /// 연결된 Spotify 계정. 연결되기 전에는 nil.
    private(set) var user: String?

    private static let lyricsTimeout: TimeInterval = 8
    private static let loginTimeout: TimeInterval = 5 * 60
    /// 프로세스가 죽었을 때 다시 띄우기까지 기다리는 시간. 계속 죽으면 점점 길게 기다린다.
    private static let restartDelays: [TimeInterval] = [5, 15, 60, 300]

    private let executable = Bundle.main.url(forAuxiliaryExecutable: "lyrics-sidecar")
    /// 로그인 정보(credentials.json)가 놓이는 곳.
    private let directory = AppFiles.directory.appendingPathComponent("spotify", isDirectory: true)

    private var process: Process?
    private var input: FileHandle?
    /// 띄울 때마다 올린다. 이전 프로세스가 뒤늦게 보낸 출력과 종료 알림을 걸러낸다.
    private var runID = 0
    private var buffer = Data()
    private var wantsRunning = false
    private var failureCount = 0
    private var restartTask: Task<Void, Never>?
    private var loginProcess: Process?

    private var nextRequest = 0
    private var pending: [Int: (id: String, continuation: CheckedContinuation<LyricsResult, Never>)] = [:]

    init() {
        // 죽은 프로세스의 파이프에 쓰면 SIGPIPE로 앱이 같이 죽는다. 쓰기 오류로 받는다.
        signal(SIGPIPE, SIG_IGN)
    }

    /// 로그인해 있으면 띄운다. 죽으면 알아서 다시 띄운다.
    func start() {
        wantsRunning = true
        launch()
    }

    func stop() {
        wantsRunning = false
        restartTask?.cancel()
        restartTask = nil
        guard let process else { return }
        runID += 1
        // stdin을 닫으면 스스로 끝난다. 혹시 멈춰 있을 때를 위해 종료 신호도 보낸다.
        try? input?.close()
        process.terminate()
        cleanUp()
    }

    private func launch() {
        guard let executable, process == nil, loginProcess == nil, isLoggedIn else { return }
        runID += 1
        let id = runID
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // 줄 순서가 지켜지도록 Task가 아니라 메인 큐에 차례로 넣는다.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, run: id) } }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status: status, run: id) } }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer.removeAll()
    }

    private var environment: [String: String] {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment
        env["LYRICS_CACHE_DIR"] = directory.path
        return env
    }

    private func received(_ data: Data, run: Int) {
        guard run == runID else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            user = message["user"] as? String ?? ""
            failureCount = 0
        case "lyrics":
            guard let id = message["id"] as? String else { return }
            let result: LyricsResult
            switch message["status"] as? Int {
            case 200:
                let body = message["body"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                result = body.map { .found($0) } ?? .unavailable
            case 404: result = .none
            default: result = .unavailable
            }
            for (request, entry) in pending where entry.id == id { resolve(request, result) }
        case "now":
            guard message["linked"] as? Bool == true,
                  let playback = message["playback"] as? [String: Any],
                  playback["playing"] as? Bool == true,
                  let uri = playback["uri"] as? String,
                  let positionMs = (playback["positionMs"] as? NSNumber)?.doubleValue
            else {
                onLive?(nil)
                return
            }
            onLive?(Live(uri: uri, position: PlaybackPosition(trackID: uri, positionMs: positionMs, at: Date())))
        default:
            break
        }
    }

    private func exited(status: Int32, run: Int) {
        guard run == runID else { return }
        cleanUp()
        if status == 2 {
            // 저장된 로그인 정보가 없거나 더는 통하지 않는다. 지워서 메뉴가 다시 로그인을 권하게 한다.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("credentials.json"))
            return
        }
        guard wantsRunning else { return }
        let delay = Self.restartDelays[min(failureCount, Self.restartDelays.count - 1)]
        failureCount += 1
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.wantsRunning else { return }
            self.launch()
        }
    }

    private func cleanUp() {
        process = nil
        input = nil
        user = nil
        for request in pending.keys { resolve(request, .unavailable) }
        onLive?(nil)
    }

    private func resolve(_ request: Int, _ result: LyricsResult) {
        pending.removeValue(forKey: request)?.continuation.resume(returning: result)
    }

    /// Spotify 자체 가사. `trackID`는 base62 id(`spotify:track:` 뒤쪽)다.
    func lyrics(trackID: String) async -> LyricsResult {
        // 막 띄운 참이면 연결될 때까지 잠깐 기다린다. 그러지 않으면 앱을 켠 직후의 곡은 Spotify 가사를 놓친다.
        for _ in 0..<50 where process != nil && user == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard process != nil, user != nil, let input else { return .unavailable }
        nextRequest += 1
        let request = nextRequest
        return await withCheckedContinuation { continuation in
            pending[request] = (trackID, continuation)
            do {
                try input.write(contentsOf: Data("lyrics \(trackID)\n".utf8))
            } catch {
                resolve(request, .unavailable)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.lyricsTimeout * 1_000_000_000))
                self?.resolve(request, .unavailable)
            }
        }
    }

    /// 브라우저에서 Spotify 로그인을 받아 로그인 정보를 저장한다. 끝난 뒤 `start()`는 부르는 쪽이 한다.
    func login() async -> LoginResult {
        guard let executable else { return .failed }
        loginProcess?.terminate()
        let restart = wantsRunning
        stop()
        wantsRunning = restart

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--login"]
        process.environment = environment
        // 로그인 주소를 stdout에 적는다. 브라우저는 사이드카가 직접 연다.
        process.standardOutput = FileHandle.nullDevice
        loginProcess = process
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.loginTimeout * 1_000_000_000))
            if !Task.isCancelled { process.terminate() }
        }
        let succeeded: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
        timeout.cancel()
        // 그사이 다른 로그인이 시작됐거나 로그아웃했다면 이 시도는 버려진 것이다.
        guard loginProcess === process else { return .cancelled }
        loginProcess = nil
        return succeeded && isLoggedIn ? .loggedIn : .failed
    }

    /// 프로세스를 내리고 저장된 로그인 정보를 지운다.
    func logout() {
        loginProcess?.terminate()
        loginProcess = nil
        let restart = wantsRunning
        stop()
        wantsRunning = restart
        try? FileManager.default.removeItem(at: directory)
    }
}
