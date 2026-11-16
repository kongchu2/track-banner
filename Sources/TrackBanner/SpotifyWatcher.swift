import AppKit

struct Track {
    let id: String  // e.g. spotify:track:4cOdK2wGLETKBW3PvgPWqT
    let name: String
    let artist: String
    let album: String
    /// 곡 길이(ms). 모르면 nil.
    var durationMs: Int? = nil
}

/// 어느 시각에 곡의 어디를 재생하고 있었는지. 가사를 재생 위치에 맞추는 데 쓴다.
struct PlaybackPosition {
    let trackID: String
    let positionMs: Double
    let at: Date
}

/// Spotify가 재생 상태가 바뀔 때마다 보내는 distributed notification을 구독한다.
@MainActor
final class SpotifyWatcher: NSObject {
    nonisolated private static let bundleID = "com.spotify.client"

    /// 알림이 올 때마다 그 시점의 상태를 알린다. 중복 제거는 PlaybackCoordinator가 한다.
    var onState: ((PlaybackState) -> Void)?
    /// 재생 중이라는 알림에 실려 온 재생 위치. `onState`보다 먼저 알린다.
    var onPosition: ((PlaybackPosition) -> Void)?

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

    /// 지금 재생 중인 곡과 그 재생 위치. Spotify는 재생 상태가 바뀔 때만 알림을 보내므로,
    /// 앱을 켠 시점의 곡과 재생 도중의 위치는 AppleScript로 직접 물어본다(처음 한 번 자동화 권한 허용이 필요하다).
    nonisolated static func currentTrack() -> (track: Track, position: PlaybackPosition)? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        // 위 확인 직후 Spotify가 종료되면 tell이 Spotify를 다시 실행시키므로 스크립트 안에서 한 번 더 확인한다.
        let source = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is not playing then return ""
                set t to current track
                -- 실수를 글자로 바꾸면 소수점이 지역 설정을 따르므로 ms 단위 정수로 받는다.
                set positionMs to ((player position) * 1000) div 1
                return (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & positionMs
            end tell
        end if
        return ""
        """
        let asked = Date()
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue else { return nil }
        // 위치는 묻고 답을 받는 사이 어느 시점의 값이다. 그 가운데로 본다.
        let at = asked.addingTimeInterval(Date().timeIntervalSince(asked) / 2)
        let f = result.components(separatedBy: "\n")
        guard f.count == 6, f[0].hasPrefix("spotify:"), !f[0].hasPrefix("spotify:ad:") else { return nil }
        let track = Track(id: f[0], name: f[1], artist: f[2], album: f[3], durationMs: Int(f[4]).flatMap { $0 > 0 ? $0 : nil })
        return (track, PlaybackPosition(trackID: f[0], positionMs: Double(f[5]) ?? 0, at: at))
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

        // "Playback Position"은 초, "Duration"은 ms다.
        if let seconds = (info["Playback Position"] as? NSNumber)?.doubleValue {
            onPosition?(PlaybackPosition(trackID: id, positionMs: seconds * 1000, at: Date()))
        }
        let duration = (info["Duration"] as? NSNumber)?.intValue
        onState?(.playing(Track(
            id: id,
            name: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            durationMs: duration.flatMap { $0 > 0 ? $0 : nil }
        )))
    }
}
