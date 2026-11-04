import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotifyWatcher = SpotifyWatcher()
    private let banner = BannerController()
    private var statusItem: NSStatusItem?
    private var latestTrackID: String?

    private static let showArtworkKey = "ShowArtworkInMenuBar"
    private static let showTitleKey = "ShowTitleInMenuBar"
    private static let showArtistKey = "ShowArtistInMenuBar"
    private var showsArtwork: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showArtworkKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showArtworkKey); updateStatusItem() }
    }
    private var showsTitle: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showTitleKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showTitleKey); updateStatusItem() }
    }
    private var showsArtist: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showArtistKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showArtistKey); updateStatusItem() }
    }
    private static let bannerDisabledKey = "BannerDisabled"
    /// 곡이 바뀔 때 배너를 띄우지 않는다(메뉴 막대 표시만 쓰고 싶을 때).
    private var isBannerDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.bannerDisabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bannerDisabledKey) }
    }
    private var latestArtwork: NSImage?
    private var latestTrack: Track?

    /// 메뉴 막대 아이콘(커버)과 글자(제목/아티스트)를 현재 설정과 곡에 맞게 갱신한다.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        if showsArtwork, let latestArtwork {
            button.image = StatusIcon.make(artwork: latestArtwork)
        } else {
            button.image = StatusIcon.make()
        }

        var parts: [String] = []
        if let track = latestTrack {
            if showsTitle, !track.name.isEmpty { parts.append(track.name) }
            if showsArtist, !track.artist.isEmpty { parts.append(track.artist) }
        }
        let text = parts.joined(separator: " – ")
        // 메뉴 막대가 너무 길어지지 않도록 자른다.
        button.title = text.count > 40 ? String(text.prefix(39)) + "…" : text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        statusItem?.length = text.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

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
        spotifyWatcher.onStop = { [weak self] in self?.playerStopped() }
        spotifyWatcher.start()
        loadCurrentTrackArtwork()
    }

    private var isQueryingCurrentTrack = false
    /// 곡 변경·정지가 있을 때마다 늘어난다. 늦게 끝난 시작 시 조회가 그 뒤의 상태를 덮어쓰지 않게 한다.
    private var trackEventCount = 0

    /// 앱을 켠 시점에 이미 재생 중인 곡의 커버를 메뉴 막대에만 반영한다(배너는 띄우지 않는다).
    /// 메뉴 막대 표시 옵션이 하나라도 켜져 있고 아이콘이 보일 때만 물어봐서, 쓰지 않는 표시를 위해 자동화 권한을 요청하지 않는다.
    private func loadCurrentTrackArtwork() {
        guard showsArtwork || showsTitle || showsArtist, !isStatusItemHidden,
              latestTrackID == nil, !isQueryingCurrentTrack else { return }
        isQueryingCurrentTrack = true
        let eventCountAtStart = trackEventCount
        Task {
            defer { isQueryingCurrentTrack = false }
            guard let track = await Task.detached(operation: { SpotifyWatcher.currentTrack() }).value else { return }
            // 그사이 곡 변경·정지 알림이 왔으면 그쪽이 최신이다(자동화 권한 팝업 동안 조회가 오래 멈출 수 있다).
            guard trackEventCount == eventCountAtStart else { return }
            showInStatusItem(track)
            let artwork = await ArtworkLoader.artwork(for: track)
            guard latestTrackID == track.id else { return }
            latestArtwork = artwork
            updateStatusItem()
        }
    }

    private func trackChanged(_ track: Track) {
        // 앱을 켤 때 조회해 이미 표시 중인 곡을 재생한 경우: 받아 둔 커버를 그대로 써서
        // 기본 아이콘으로 깜빡이거나 다시 받지 않는다.
        if track.id == latestTrackID, let artwork = latestArtwork {
            trackEventCount += 1
            latestTrack = track
            updateStatusItem()
            if !isBannerDisabled { banner.show(track: track, artwork: artwork) }
            return
        }
        showInStatusItem(track)
        Task {
            let artwork = await ArtworkLoader.artwork(for: track)
            // 커버를 받는 사이 곡이 또 바뀌었으면 옛 알림은 버린다.
            guard latestTrackID == track.id else { return }
            latestArtwork = artwork
            updateStatusItem()
            if !isBannerDisabled { banner.show(track: track, artwork: artwork) }
        }
    }

    /// 제목·아티스트는 이미 알고 있으니 커버 다운로드를 기다리지 않고 바로 반영한다.
    /// 이전 곡 커버가 남지 않도록 새 커버가 올 때까지는 기본 아이콘을 보여준다.
    private func showInStatusItem(_ track: Track) {
        trackEventCount += 1
        latestTrackID = track.id
        latestTrack = track
        latestArtwork = nil
        updateStatusItem()
    }

    /// Spotify가 정지·종료되면 메뉴 막대에서 곡 정보를 지운다.
    private func playerStopped() {
        trackEventCount += 1
        latestTrackID = nil
        latestTrack = nil
        latestArtwork = nil
        updateStatusItem()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.make()
        let menu = NSMenu()
        let launchAtLogin = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        let disableBanner = NSMenuItem(title: "배너 알림 끄기", action: #selector(toggleBannerDisabled(_:)), keyEquivalent: "")
        disableBanner.target = self
        menu.addItem(disableBanner)
        let showArt = NSMenuItem(title: "메뉴 막대에 앨범 커버 표시", action: #selector(toggleShowArtwork(_:)), keyEquivalent: "")
        showArt.target = self
        menu.addItem(showArt)
        let showTitle = NSMenuItem(title: "메뉴 막대에 제목 표시", action: #selector(toggleShowTitle(_:)), keyEquivalent: "")
        showTitle.target = self
        menu.addItem(showTitle)
        let showArtist = NSMenuItem(title: "메뉴 막대에 아티스트 표시", action: #selector(toggleShowArtist(_:)), keyEquivalent: "")
        showArtist.target = self
        menu.addItem(showArtist)
        let hide = NSMenuItem(title: "메뉴 막대에서 숨기기", action: #selector(hideStatusItem(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Track Banner 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.isVisible = !isStatusItemHidden
        statusItem = item
    }

    // 아이콘을 숨긴 뒤 Finder 등에서 앱을 다시 실행하면 아이콘을 되살린다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        isStatusItemHidden = false
        loadCurrentTrackArtwork()
        return false
    }

    @objc private func toggleBannerDisabled(_ sender: NSMenuItem) {
        isBannerDisabled.toggle()
    }

    @objc private func toggleShowArtwork(_ sender: NSMenuItem) {
        showsArtwork.toggle()
        loadCurrentTrackArtwork()
    }

    @objc private func toggleShowTitle(_ sender: NSMenuItem) {
        showsTitle.toggle()
        loadCurrentTrackArtwork()
    }

    @objc private func toggleShowArtist(_ sender: NSMenuItem) {
        showsArtist.toggle()
        loadCurrentTrackArtwork()
    }

    @objc private func hideStatusItem(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "메뉴 막대 아이콘을 숨길까요?"
        alert.informativeText = "알림은 계속 표시됩니다. 아이콘을 다시 보려면 Finder에서 Track Banner를 한 번 더 실행하세요."
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
        if menuItem.action == #selector(toggleBannerDisabled(_:)) {
            menuItem.state = isBannerDisabled ? .on : .off
        }
        if menuItem.action == #selector(toggleShowArtwork(_:)) {
            menuItem.state = showsArtwork ? .on : .off
        }
        if menuItem.action == #selector(toggleShowTitle(_:)) {
            menuItem.state = showsTitle ? .on : .off
        }
        if menuItem.action == #selector(toggleShowArtist(_:)) {
            menuItem.state = showsArtist ? .on : .off
        }
        return true
    }
}
