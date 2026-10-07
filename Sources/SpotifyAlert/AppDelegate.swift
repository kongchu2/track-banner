import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotifyWatcher = SpotifyWatcher()
    private let spotifastWatcher = SpotifastWatcher()
    private let banner = BannerController()
    private var statusItem: NSStatusItem?
    private var latestTrackID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        spotifyWatcher.onTrackChange = { [weak self] in self?.trackChanged($0) }
        spotifastWatcher.onTrackChange = { [weak self] in self?.trackChanged($0) }
        spotifyWatcher.start()
        spotifastWatcher.start()
    }

    private func trackChanged(_ track: Track) {
        latestTrackID = track.id
        Task {
            let artwork = await ArtworkLoader.artwork(for: track)
            // 커버를 받는 사이 곡이 또 바뀌었으면 옛 알림은 버린다.
            guard latestTrackID == track.id else { return }
            banner.show(track: track, artwork: artwork)
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Spotify Alert")
        let menu = NSMenu()
        menu.addItem(withTitle: "Spotify Alert 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}
