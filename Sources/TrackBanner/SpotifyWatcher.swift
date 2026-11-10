import AppKit

struct Track {
    let id: String  // e.g. spotify:track:4cOdK2wGLETKBW3PvgPWqT
    let name: String
    let artist: String
    let album: String
}

/// Spotify가 재생 상태가 바뀔 때마다 보내는 distributed notification을 구독한다.
@MainActor
final class SpotifyWatcher: NSObject {
    nonisolated private static let bundleID = "com.spotify.client"

    /// 알림이 올 때마다 그 시점의 상태를 알린다. 중복 제거는 PlaybackCoordinator가 한다.
    var onState: ((PlaybackState) -> Void)?

    func start() {
        // 앱이 비활성 상태여도 바로 받도록 deliverImmediately를 쓴다.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // Spotify를 종료하면 정지 알림 없이 사라질 수 있으므로 종료 자체도 감시한다.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spotifyTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// 지금 재생 중인 곡. Spotify는 곡이 바뀔 때만 알림을 보내므로,
    /// 앱을 켠 시점의 곡은 AppleScript로 직접 물어본다(처음 한 번 자동화 권한 허용이 필요하다).
    nonisolated static func currentTrack() -> Track? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        // 위 확인 직후 Spotify가 종료되면 tell이 Spotify를 다시 실행시키므로 스크립트 안에서 한 번 더 확인한다.
        let source = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is not playing then return ""
                set t to current track
                return (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t)
            end tell
        end if
        return ""
        """
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue else { return nil }
        let f = result.components(separatedBy: "\n")
        guard f.count == 4, f[0].hasPrefix("spotify:"), !f[0].hasPrefix("spotify:ad:") else { return nil }
        return Track(id: f[0], name: f[1], artist: f[2], album: f[3])
    }

    @objc private func spotifyTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID
        else { return }
        onState?(.stopped)
    }

    @objc private func playbackStateChanged(_ note: Notification) {
        let state = note.userInfo?["Player State"] as? String
        let id = note.userInfo?["Track ID"] as? String
        // 광고 중에는 직전 곡이 아직 재생 중인 것처럼 보이지 않도록 정지와 같게 처리한다.
        if state == "Stopped" || (state == "Playing" && id?.hasPrefix("spotify:ad:") == true) {
            onState?(.stopped)
            return
        }
        if state == "Paused" {
            onState?(.paused)
            return
        }
        guard let info = note.userInfo, state == "Playing", let id else { return }

        onState?(.playing(Track(
            id: id,
            name: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? ""
        )))
    }
}
