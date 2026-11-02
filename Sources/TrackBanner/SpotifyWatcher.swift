import Foundation

struct Track {
    let id: String  // e.g. spotify:track:4cOdK2wGLETKBW3PvgPWqT
    let name: String
    let artist: String
    let album: String
    var artworkURL: URL? = nil
}

/// Spotify가 재생 상태가 바뀔 때마다 보내는 distributed notification을 구독한다.
@MainActor
final class SpotifyWatcher: NSObject {
    var onTrackChange: ((Track) -> Void)?
    private var lastTrackID: String?

    func start() {
        // 앱이 비활성 상태여도 바로 받도록 deliverImmediately를 쓴다.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func playbackStateChanged(_ note: Notification) {
        guard let info = note.userInfo,
              info["Player State"] as? String == "Playing",
              let id = info["Track ID"] as? String,
              !id.hasPrefix("spotify:ad:"),
              id != lastTrackID  // 일시정지 후 재개는 무시
        else { return }

        lastTrackID = id
        onTrackChange?(Track(
            id: id,
            name: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? ""
        ))
    }
}
