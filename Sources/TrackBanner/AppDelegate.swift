import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotifyWatcher = SpotifyWatcher()
    private let spotifyAuth = SpotifyAuth()
    private lazy var webWatcher = WebAPIWatcher(auth: spotifyAuth)
    /// 두 소스가 본 상태를 합쳐 지금 재생 중인 곡과 배너 여부를 정한다.
    private let playback = PlaybackCoordinator()
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
        var parts: [String] = []
        if let track = latestTrack {
            if showsTitle, !track.name.isEmpty { parts.append(track.name) }
            if showsArtist, !track.artist.isEmpty { parts.append(track.artist) }
        }
        let text = parts.joined(separator: " – ")
        // 메뉴 막대가 너무 길어지지 않도록 자른다.
        let icon: NSImage
        if showsArtwork, let latestArtwork {
            icon = StatusIcon.make(artwork: latestArtwork)
        } else {
            icon = StatusIcon.make()
        }
        // 글자가 있을 때만 아이콘과 글자 사이를 벌린다.
        button.image = text.isEmpty ? icon : StatusIcon.padded(icon, trailing: 5)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Spotify 로그인이 끝나면 브라우저가 trackbanner://callback?code=... 로 돌려보낸다.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// 메뉴 막대에 보이지는 않지만, 이게 있어야 입력창에서 ⌘V/⌘C/⌘X/⌘A가 동작한다.
    private func setUpEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpEditMenu()
        setUpStatusItem()

        playback.onChange = { [weak self] in self?.playbackChanged($0, isNewTrack: $1) }
        playback.onWebStateInvalidated = { [weak self] in self?.webWatcher.restart() }
        spotifyWatcher.onState = { [weak self] in self?.playback.clientReported($0) }
        spotifyWatcher.start()

        webWatcher.onState = { [weak self] in self?.playback.webReported($0) }
        spotifyAuth.onChange = { [weak self] in self?.updateWebAPIPolling() }
        updateWebAPIPolling()

        loadCurrentTrackArtwork()
    }

    private func updateWebAPIPolling() {
        if spotifyAuth.isConnected {
            webWatcher.start()
        } else {
            webWatcher.stop()
            playback.webDisconnected()
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Task {
            let result = await spotifyAuth.handleCallback(url)
            // Task 안에서 runModal을 부르면 알림창이 떠 있는 동안 다른 MainActor 작업(폴링, 커버 로딩)이 멈춘다.
            // 런루프 블록으로 넘겨 Task 밖에서 띄운다.
            RunLoop.main.perform {
                MainActor.assumeIsolated { self.showLoginResult(result) }
            }
        }
    }

    private func showLoginResult(_ result: SpotifyAuth.CallbackResult) {
        let alert = NSAlert()
        switch result {
        case .ignored, .cancelled:
            // 우리가 시작한 로그인의 응답이 아니거나 사용자가 직접 취소했다. 알릴 것이 없다.
            return
        case .connected:
            alert.messageText = "Spotify에 연결됐습니다"
            alert.informativeText = "이제 Spotifast, 웹 플레이어 등 다른 앱에서 재생하는 곡도 따라갑니다. 브라우저 탭은 닫아도 됩니다."
        case .failed:
            alert.messageText = "Spotify 연결에 실패했습니다"
            alert.informativeText = "Client ID와 Redirect URI(\(SpotifyAuth.redirectURI))가 Spotify 대시보드 설정과 같은지 확인한 뒤 다시 시도하세요."
        case .keychainFailed:
            alert.messageText = "Spotify 연결을 저장하지 못했습니다"
            alert.informativeText = "로그인은 됐지만 키체인에 저장할 수 없었습니다. 키체인 접근을 허용한 뒤 다시 연결하세요."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var isQueryingCurrentTrack = false

    /// 앱을 켠 시점에 이미 재생 중인 곡을 메뉴 막대에만 반영한다(배너는 띄우지 않는다).
    /// 메뉴 막대 표시 옵션이 하나라도 켜져 있고 아이콘이 보일 때만 물어봐서, 쓰지 않는 표시를 위해 자동화 권한을 요청하지 않는다.
    private func loadCurrentTrackArtwork() {
        guard showsArtwork || showsTitle || showsArtist, !isStatusItemHidden,
              latestTrackID == nil, !isQueryingCurrentTrack else { return }
        isQueryingCurrentTrack = true
        let reportCountAtStart = playback.clientReportCount
        Task {
            defer { isQueryingCurrentTrack = false }
            guard let track = await Task.detached(operation: { SpotifyWatcher.currentTrack() }).value else { return }
            // 그사이 곡 변경·정지 알림이 왔으면 그쪽이 최신이다(자동화 권한 팝업 동안 조회가 오래 멈출 수 있다).
            guard playback.clientReportCount == reportCountAtStart else { return }
            playback.clientWasAlreadyPlaying(track)
        }
    }

    /// 합쳐진 재생 상태가 바뀌었을 때.
    private func playbackChanged(_ state: PlaybackState, isNewTrack: Bool) {
        switch state {
        case .playing(let track):
            show(track, withBanner: isNewTrack && !isBannerDisabled)
        case .paused, .stopped:
            clearStatusItem()
        }
    }

    /// 제목·아티스트는 이미 알고 있으니 커버 다운로드를 기다리지 않고 바로 반영한다.
    /// 이전 곡 커버가 남지 않도록 새 커버가 올 때까지는 기본 아이콘을 보여준다.
    private func show(_ track: Track, withBanner: Bool) {
        latestTrackID = track.id
        latestTrack = track
        latestArtwork = nil
        updateStatusItem()
        Task {
            let artwork = await ArtworkLoader.artwork(for: track)
            // 커버를 받는 사이 곡이 또 바뀌었거나 멈췄으면 옛 알림은 버린다.
            guard latestTrackID == track.id else { return }
            latestArtwork = artwork
            updateStatusItem()
            if withBanner { banner.show(track: track, artwork: artwork) }
        }
    }

    /// 일시정지·정지·종료되면 메뉴 막대에서 곡 정보를 지운다.
    private func clearStatusItem() {
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
        let webAPI = NSMenuItem(title: "Spotify 연결(다른 앱 재생 추적)…", action: #selector(toggleWebAPI(_:)), keyEquivalent: "")
        webAPI.target = self
        menu.addItem(webAPI)
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

    @objc private func toggleWebAPI(_ sender: NSMenuItem) {
        if spotifyAuth.isConnected {
            spotifyAuth.disconnect()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spotify 연결"
        alert.informativeText = """
        Spotifast, 웹 플레이어처럼 알림을 보내지 않는 앱의 재생도 추적하려면 Spotify Web API에 연결합니다.

        1. developer.spotify.com/dashboard 에서 앱을 만듭니다.
        2. Redirect URI에 \(SpotifyAuth.redirectURI) 를 추가하고 Web API를 선택합니다.
        3. 앱의 Client ID를 아래에 붙여넣습니다.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Client ID"
        field.stringValue = spotifyAuth.clientID ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "연결")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        spotifyAuth.clientID = id
        spotifyAuth.beginLogin()
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
        if menuItem.action == #selector(toggleWebAPI(_:)) {
            menuItem.title = spotifyAuth.isConnected ? "Spotify 연결 해제" : "Spotify 연결(다른 앱 재생 추적)…"
            menuItem.state = spotifyAuth.isConnected ? .on : .off
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
