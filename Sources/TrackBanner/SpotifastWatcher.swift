import AppKit

/// Spotifast(https://github.com/crmne/spotifast)는 Spotify 공식 클라이언트와 달리
/// distributed notification을 보내지 않으므로, CLI의 `now-playing --raw`를 주기적으로 호출한다.
@MainActor
final class SpotifastWatcher {
    private static let bundleID = "rocks.spotifast.Spotifast"
    private static let pollInterval: TimeInterval = 1

    var onTrackChange: ((Track) -> Void)?
    private var lastTrackID: String?
    private var timer: Timer?
    private var isPolling = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        // 실행 중일 때만 호출한다. 꺼져 있을 때 CLI를 부르면 앱이 새로 뜰 수 있다.
        guard !isPolling,
              let executable = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.bundleID)
                .first?.executableURL
        else { return }

        isPolling = true
        Task {
            let fields = await Task.detached { Self.nowPlaying(executable) }.value
            isPolling = false
            if let fields { handle(fields) }
        }
    }

    /// 필드 순서: state, title, artists, album, position_ms, duration_ms, volume, shuffle, repeat, art_url, saved, device
    private func handle(_ fields: [String]) {
        guard fields.count >= 10, fields[0] == "playing" else { return }

        // CLI가 트랙 ID를 주지 않으므로 제목·아티스트·앨범 조합으로 곡을 구분한다.
        let id = "spotifast:" + fields[1...3].joined(separator: "\t")
        guard id != lastTrackID else { return }  // 일시정지 후 재개는 무시
        lastTrackID = id

        onTrackChange?(Track(
            id: id,
            name: fields[1],
            artist: fields[2],
            album: fields[3],
            artworkURL: URL(string: fields[9])
        ))
    }

    nonisolated private static func nowPlaying(_ executable: URL) -> [String]? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["now-playing", "--raw"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\t")
    }
}
