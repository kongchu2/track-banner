import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotifyWatcher = SpotifyWatcher()
    private let spotifastWatcher = SpotifastWatcher()
    private let banner = BannerController()
    private var statusItem: NSStatusItem?
    private var latestTrackID: String?

    private static let hideStatusItemKey = "HideStatusItem"
    private var isStatusItemHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hideStatusItemKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.hideStatusItemKey)
            statusItem?.isVisible = !newValue
        }
    }

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
        let launchAtLogin = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        let hide = NSMenuItem(title: "메뉴 막대에서 숨기기", action: #selector(hideStatusItem(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Spotify Alert 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.isVisible = !isStatusItemHidden
        statusItem = item
    }

    // 아이콘을 숨긴 뒤 Finder 등에서 앱을 다시 실행하면 아이콘을 되살린다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        isStatusItemHidden = false
        return false
    }

    @objc private func hideStatusItem(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "메뉴 막대 아이콘을 숨길까요?"
        alert.informativeText = "알림은 계속 표시됩니다. 아이콘을 다시 보려면 Finder에서 SpotifyAlert를 한 번 더 실행하세요."
        alert.addButton(withTitle: "숨기기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            isStatusItemHidden = true
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                // 시스템 설정에서 사용자가 꺼둔 상태. 직접 켜도록 설정 화면을 연다.
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    // 메뉴를 열 때마다 실제 등록 상태를 체크 표시에 반영한다.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            switch SMAppService.mainApp.status {
            case .enabled: menuItem.state = .on
            case .requiresApproval: menuItem.state = .mixed
            default: menuItem.state = .off
            }
        }
        return true
    }
}
