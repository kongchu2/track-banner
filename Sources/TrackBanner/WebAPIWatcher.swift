import AppKit

/// Spotify Web API의 currently-playing을 주기적으로 물어본다.
/// 공식 클라이언트가 아닌 앱(Spotifast, 웹 플레이어 등)은 distributed notification을 보내지 않으므로 이 방식으로 따라간다.
@MainActor
final class WebAPIWatcher {
    /// 재생 중일 때의 폴링 간격.
    private static let playingInterval: TimeInterval = 3
    /// 재생 중이 아닐 때는 천천히 물어봐서 요청 수를 줄인다.
    private static let idleInterval: TimeInterval = 10
    /// `item`이 잠깐 비어 오는 응답은 이만큼까지 무시하고, 계속되면 정지로 본다.
    private static let missingItemLimit = 3

    private struct Playback: Decodable {
        struct Named: Decodable { let name: String }
        struct Item: Decodable {
            let uri: String
            let name: String
            // 곡에만 있다.
            let artists: [Named]?
            let album: Named?
            // 팟캐스트 에피소드에만 있다.
            let show: Named?
        }
        let is_playing: Bool
        let currently_playing_type: String?
        let item: Item?
    }

    /// 폴링할 때마다 지금 상태를 알린다(바뀌지 않았어도 알린다).
    var onState: ((PlaybackState) -> Void)?

    private let auth: SpotifyAuth
    private var task: Task<Void, Never>?
    private var missingItemCount = 0

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    func start() {
        guard task == nil else { return }
        run(after: 0)
    }

    func stop() {
        task?.cancel()
        task = nil
        missingItemCount = 0
    }

    /// 받는 중인 응답을 버리고 조금 뒤에 다시 물어본다. 이미 옛 상태가 된 응답이 반영되지 않게 한다.
    func restart() {
        guard task != nil else { return }
        stop()
        run(after: Self.playingInterval)
    }

    private func run(after initialDelay: TimeInterval) {
        task = Task { [weak self] in
            var delay = initialDelay
            while true {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                delay = await self.poll()
            }
        }
    }

    /// 한 번 물어보고, 다음에 물어볼 때까지 기다릴 시간(초)을 돌려준다.
    private func poll() async -> TimeInterval {
        guard let token = await auth.validAccessToken() else { return 10 }

        // additional_types가 없으면 에피소드를 재생할 때 item이 비어서 온다.
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=episode")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, !Task.isCancelled else { return 5 }

        switch http.statusCode {
        case 200:
            guard let playback = try? JSONDecoder().decode(Playback.self, from: data) else { return 5 }
            return report(state(of: playback))
        case 204:
            // 재생 중인 기기가 없다.
            missingItemCount = 0
            return report(.stopped)
        case 401:
            auth.invalidateAccessToken()
            return 1
        case 429:
            return TimeInterval(http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 10) + 1
        default:
            return 5
        }
    }

    private func report(_ state: PlaybackState?) -> TimeInterval {
        guard let state else { return Self.playingInterval }
        onState?(state)
        return state.isPlaying ? Self.playingInterval : Self.idleInterval
    }

    /// 응답이 뜻하는 상태. 판단할 수 없는 응답이면 nil(직전 상태를 유지한다).
    private func state(of playback: Playback) -> PlaybackState? {
        // 광고 중에는 직전 곡이 아직 재생 중인 것처럼 보이지 않도록 정지와 같게 처리한다.
        if playback.currently_playing_type == "ad" {
            missingItemCount = 0
            return .stopped
        }
        guard let item = playback.item else {
            // 곡 사이에 item이 잠깐 비어 올 수 있다. 바로 정지로 보면 같은 곡의 배너가 다시 뜬다.
            missingItemCount += 1
            return missingItemCount >= Self.missingItemLimit ? .stopped : nil
        }
        missingItemCount = 0
        guard playback.is_playing else { return .paused }

        // 에피소드는 아티스트·앨범 대신 프로그램 이름을 쓴다. 로컬 파일(spotify:local:)도 그대로 표시한다.
        return .playing(Track(
            id: item.uri,
            name: item.name,
            artist: item.artists?.map(\.name).joined(separator: ", ") ?? item.show?.name ?? "",
            album: item.album?.name ?? item.show?.name ?? ""
        ))
    }
}
