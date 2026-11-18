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
    private let sidecar = LyricsSidecar()
    private let translator = LyricsTranslator()
    private lazy var lyrics = LyricsController(store: LyricsStore(sidecar: sidecar, translator: translator))
    /// 메뉴에서 번역 언어를 막 고른 시각. 그 직후에 내려받을 언어가 있다고 나오면 바로 내려받기 창을 띄운다.
    /// 그 밖의 때(곡이 바뀌어서 알게 됐을 때)는 창을 띄우지 않고 메뉴에만 표시한다.
    private var translationChosenAt: Date?
    private let lyricsPanel = LyricsPanelController()
    /// 지금 부르는 가사 줄. 가사가 없는 곡이거나 간주면 nil.
    private var lyricLine: LyricsController.Line?
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
    private static let showFloatingLyricsKey = "ShowFloatingLyrics"
    private static let showMenuBarLyricsKey = "ShowLyricsInMenuBar"
    private var showsFloatingLyrics: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showFloatingLyricsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showFloatingLyricsKey); updateLyrics() }
    }
    private static let hideLyricsOnHoverKey = "HideLyricsOnHover"
    /// 화면의 가사 위로 마우스를 올리면 가사를 숨긴다.
    private var hidesLyricsOnHover: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hideLyricsOnHoverKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hideLyricsOnHoverKey); lyricsPanel.hidesOnHover = newValue }
    }
    private static let hideLyricsWhileTypingKey = "HideLyricsWhileTyping"
    private let typingWatcher = TypingWatcher()
    /// 화면의 가사가 글자를 치고 있는 자리를 가리면, 치는 동안 가사를 숨긴다. 손쉬운 사용 권한이 필요하다.
    private var hidesLyricsWhileTyping: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hideLyricsWhileTypingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hideLyricsWhileTypingKey); updateLyrics() }
    }
    private static let lyricsBackgroundKey = "LyricsBackgroundStyle"
    /// 화면의 가사 배경을 앨범 커버로 꾸미는 방식. nil이면 기본 유리 배경이다.
    private var lyricsBackgroundStyle: LyricsPanelController.BackgroundStyle? {
        get { UserDefaults.standard.string(forKey: Self.lyricsBackgroundKey).flatMap(LyricsPanelController.BackgroundStyle.init) }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: Self.lyricsBackgroundKey)
            lyricsPanel.backgroundStyle = newValue
        }
    }

    /// 가사 패널의 배경을 지금 곡의 커버에 맞춘다.
    /// 곡이 바뀌어 새 커버를 받는 동안에는 부르지 않는다. 그사이 앞 곡의 배경이 남아 있다가 새 것으로 겹쳐 바뀐다.
    private func updateLyricsCover() {
        lyricsPanel.artwork = latestArtwork
    }
    private static let lyricsPronunciationKey = "LyricsPronunciationStyle"
    /// 화면의 가사에 발음을 로마자로 붙이는 방식. nil이면 붙이지 않는다.
    private var lyricsPronunciationStyle: LyricsController.PronunciationStyle? {
        get { UserDefaults.standard.string(forKey: Self.lyricsPronunciationKey).flatMap(LyricsController.PronunciationStyle.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.lyricsPronunciationKey); updateLyrics() }
    }
    private static let lyricsTranslationKey = "LyricsTranslationLanguage"
    /// 화면의 가사 아래에 번역을 붙일 언어(ko, ja, …). nil이면 번역하지 않는다.
    private var lyricsTranslationLanguage: String? {
        get { LyricsTranslator.isSupported ? UserDefaults.standard.string(forKey: Self.lyricsTranslationKey) : nil }
        set { UserDefaults.standard.set(newValue, forKey: Self.lyricsTranslationKey); updateLyrics() }
    }
    private var showsMenuBarLyrics: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showMenuBarLyricsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showMenuBarLyricsKey); updateLyrics() }
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
        var text = parts.joined(separator: " – ")
        // 부르는 줄이 있는 동안은 가사가 제목·아티스트 자리를 쓴다. 간주와 가사 없는 곡에서는 제목·아티스트로 돌아간다.
        if showsMenuBarLyrics, let lyricLine { text = lyricLine.text }
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
        setUpLyrics()
        spotifyWatcher.start()

        spotifyAuth.onChange = { [weak self] in self?.updateWebAPIPolling() }
        updateWebAPIPolling()

        loadCurrentTrackArtwork()
    }

    /// 두 소스의 재생 상태를 PlaybackCoordinator에, 재생 위치를 가사에 잇는다.
    /// 위치는 곡이 그대로여도 계속 바뀌므로 곡과 따로 흘린다.
    private func setUpLyrics() {
        lyrics.onLine = { [weak self] in self?.lyricLineChanged($0) }
        lyrics.clientPosition = {
            await Task.detached { SpotifyWatcher.currentTrack()?.position }.value
        }
        spotifyWatcher.onPosition = { [weak self] in self?.lyrics.report($0, from: .client) }
        spotifyWatcher.onState = { [weak self] state in
            if !state.isPlaying { self?.lyrics.clearPosition(from: .client) }
            self?.playback.clientReported(state)
        }
        webWatcher.onPosition = { [weak self] in self?.lyrics.report($0, from: .web) }
        webWatcher.onState = { [weak self] state in
            if !state.isPlaying { self?.lyrics.clearPosition(from: .web) }
            self?.playback.webReported(state)
        }
        sidecar.onLive = { [weak self] in self?.connectReported($0) }
        translator.onLanguagesInstalled = { [weak self] in self?.lyrics.loadTranslation() }
        lyrics.onLanguageNeeded = { [weak self] source in
            guard let self, let chosen = self.translationChosenAt else { return }
            self.translationChosenAt = nil
            if Date().timeIntervalSince(chosen) < 10 { self.downloadTranslationLanguage(source: source) }
        }
        lyricsPanel.hidesOnHover = hidesLyricsOnHover
        typingWatcher.onArea = { [weak self] in self?.lyricsPanel.typingArea = $0 }
        lyricsPanel.backgroundStyle = lyricsBackgroundStyle
        updateLyricsCover()
        updateLyrics()
    }

    /// 가사 표시 설정이 바뀌었을 때. 둘 다 꺼져 있으면 가사를 찾지 않고 사이드카도 띄우지 않는다.
    private func updateLyrics() {
        let enabled = showsFloatingLyrics || showsMenuBarLyrics
        lyrics.isEnabled = enabled
        // 발음과 번역은 화면에 띄운 가사에만 붙는다.
        lyrics.pronunciationStyle = showsFloatingLyrics ? lyricsPronunciationStyle : nil
        lyrics.translationLanguage = showsFloatingLyrics ? lyricsTranslationLanguage : nil
        if enabled { sidecar.start() } else { sidecar.stop() }
        typingWatcher.isEnabled = showsFloatingLyrics && hidesLyricsWhileTyping
        lyricsPanel.show(showsFloatingLyrics ? lyricLine : nil)
        updateStatusItem()
    }

    private func lyricLineChanged(_ line: LyricsController.Line?) {
        lyricLine = line
        if showsFloatingLyrics { lyricsPanel.show(line) }
        if showsMenuBarLyrics { updateStatusItem() }
    }

    /// Web API가 다음 폴링 때에야 알게 될 곡 변경을 Connect가 먼저 알려 왔을 때, 그 곡에 대해 한 번만 폴링을 앞당긴다.
    private var hurriedPollURI: String?

    /// Spotify Connect(사이드카)가 알린 재생 상태.
    private func connectReported(_ live: LyricsSidecar.Live?) {
        guard let live else {
            lyrics.clearPosition(from: .connect)
            return
        }
        lyrics.report(live.position, from: .connect)
        if live.uri != latestTrackID, live.uri != hurriedPollURI {
            hurriedPollURI = live.uri
            webWatcher.pollSoon()
        }
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

    /// 앱을 켠 시점에 이미 재생 중인 곡을 메뉴 막대와 가사에만 반영한다(배너는 띄우지 않는다).
    /// 그 곡을 보여 줄 표시가 하나라도 켜져 있을 때만 물어봐서, 쓰지 않는 표시를 위해 자동화 권한을 요청하지 않는다.
    private func loadCurrentTrackArtwork() {
        let showsInMenuBar = (showsArtwork || showsTitle || showsArtist || showsMenuBarLyrics) && !isStatusItemHidden
        guard showsInMenuBar || showsFloatingLyrics, latestTrackID == nil, !isQueryingCurrentTrack else { return }
        isQueryingCurrentTrack = true
        let reportCountAtStart = playback.clientReportCount
        Task {
            defer { isQueryingCurrentTrack = false }
            guard let current = await Task.detached(operation: { SpotifyWatcher.currentTrack() }).value else { return }
            // 그사이 곡 변경·정지 알림이 왔으면 그쪽이 최신이다(자동화 권한 팝업 동안 조회가 오래 멈출 수 있다).
            guard playback.clientReportCount == reportCountAtStart else { return }
            lyrics.report(current.position, from: .client)
            playback.clientWasAlreadyPlaying(current.track)
        }
    }

    /// 합쳐진 재생 상태가 바뀌었을 때.
    private func playbackChanged(_ state: PlaybackState, isNewTrack: Bool) {
        switch state {
        case .playing(let track):
            lyrics.setTrack(track)
            show(track, withBanner: isNewTrack && !isBannerDisabled)
        case .paused, .stopped:
            lyrics.setTrack(nil)
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
            updateLyricsCover()
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
        menu.addItem(.separator())
        let floatingLyrics = NSMenuItem(title: "화면에 가사 띄우기", action: #selector(toggleFloatingLyrics(_:)), keyEquivalent: "")
        floatingLyrics.target = self
        menu.addItem(floatingLyrics)
        let hideOnHover = NSMenuItem(title: "마우스를 올리면 가사 숨기기", action: #selector(toggleHideLyricsOnHover(_:)), keyEquivalent: "")
        hideOnHover.target = self
        hideOnHover.indentationLevel = 1
        menu.addItem(hideOnHover)
        let hideWhileTyping = NSMenuItem(title: "입력 중인 곳을 가리면 가사 숨기기", action: #selector(toggleHideLyricsWhileTyping(_:)), keyEquivalent: "")
        hideWhileTyping.target = self
        hideWhileTyping.indentationLevel = 1
        menu.addItem(hideWhileTyping)
        let lyricsBackground = NSMenuItem(title: "가사 배경", action: nil, keyEquivalent: "")
        lyricsBackground.indentationLevel = 1
        let backgrounds = NSMenu()
        for (title, style) in [("기본", nil), ("투명", LyricsPanelController.BackgroundStyle.clear), ("앨범 색", .color), ("앨범 커버", .cover)] {
            let item = NSMenuItem(title: title, action: #selector(selectLyricsBackground(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style?.rawValue
            backgrounds.addItem(item)
            if style == nil { backgrounds.addItem(.separator()) }
        }
        lyricsBackground.submenu = backgrounds
        menu.addItem(lyricsBackground)
        let pronunciation = NSMenuItem(title: "발음 표기(로마자)", action: nil, keyEquivalent: "")
        pronunciation.indentationLevel = 1
        let styles = NSMenu()
        for (title, style) in [("끄기", nil), ("글자 위에", LyricsController.PronunciationStyle.above), ("가사 아래에", .below)] {
            let item = NSMenuItem(title: title, action: #selector(selectLyricsPronunciation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style?.rawValue
            styles.addItem(item)
            if style == nil { styles.addItem(.separator()) }
        }
        pronunciation.submenu = styles
        menu.addItem(pronunciation)
        if LyricsTranslator.isSupported {
            let translation = NSMenuItem(title: "가사 번역", action: nil, keyEquivalent: "")
            translation.indentationLevel = 1
            let languages = NSMenu()
            let off = NSMenuItem(title: "끄기", action: #selector(selectLyricsTranslation(_:)), keyEquivalent: "")
            off.target = self
            languages.addItem(off)
            languages.addItem(.separator())
            for language in LyricsTranslator.languages {
                let item = NSMenuItem(title: language.name, action: #selector(selectLyricsTranslation(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = language.id
                languages.addItem(item)
            }
            languages.addItem(.separator())
            let download = NSMenuItem(title: "번역 언어 내려받기…", action: #selector(downloadTranslationLanguage(_:)), keyEquivalent: "")
            download.target = self
            languages.addItem(download)
            translation.submenu = languages
            menu.addItem(translation)
        }
        let menuBarLyrics = NSMenuItem(title: "메뉴 막대에 가사 표시", action: #selector(toggleMenuBarLyrics(_:)), keyEquivalent: "")
        menuBarLyrics.target = self
        menu.addItem(menuBarLyrics)
        let lyricsLogin = NSMenuItem(title: "Spotify 가사 로그인…", action: #selector(toggleLyricsLogin(_:)), keyEquivalent: "")
        lyricsLogin.target = self
        menu.addItem(lyricsLogin)
        menu.addItem(.separator())
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

    @objc private func toggleFloatingLyrics(_ sender: NSMenuItem) {
        showsFloatingLyrics.toggle()
        loadCurrentTrackArtwork()
    }

    @objc private func toggleHideLyricsOnHover(_ sender: NSMenuItem) {
        hidesLyricsOnHover.toggle()
    }

    @objc private func toggleHideLyricsWhileTyping(_ sender: NSMenuItem) {
        hidesLyricsWhileTyping.toggle()
        // 다른 앱의 커서 위치는 손쉬운 사용 권한이 있어야 읽을 수 있다. 켤 때 한 번 안내한다.
        if hidesLyricsWhileTyping, !TypingWatcher.isTrusted { TypingWatcher.requestAccess() }
    }

    @objc private func selectLyricsBackground(_ sender: NSMenuItem) {
        lyricsBackgroundStyle = (sender.representedObject as? String).flatMap(LyricsPanelController.BackgroundStyle.init)
    }

    @objc private func selectLyricsPronunciation(_ sender: NSMenuItem) {
        lyricsPronunciationStyle = (sender.representedObject as? String).flatMap(LyricsController.PronunciationStyle.init)
    }

    @objc private func selectLyricsTranslation(_ sender: NSMenuItem) {
        let language = sender.representedObject as? String
        translationChosenAt = language == nil ? nil : Date()
        lyricsTranslationLanguage = language
    }

    @objc private func downloadTranslationLanguage(_ sender: NSMenuItem) {
        guard let source = lyrics.languageToDownload else { return }
        downloadTranslationLanguage(source: source)
    }

    /// 시스템의 내려받기 창을 띄운다. 내려받기가 끝나면 번역기가 알려 와서 지금 곡의 번역을 다시 가져온다.
    private func downloadTranslationLanguage(source: String) {
        guard let target = lyricsTranslationLanguage else { return }
        Task { await translator.download(source: source, target: target) }
    }

    @objc private func toggleMenuBarLyrics(_ sender: NSMenuItem) {
        showsMenuBarLyrics.toggle()
        loadCurrentTrackArtwork()
    }

    @objc private func toggleLyricsLogin(_ sender: NSMenuItem) {
        if sidecar.isLoggedIn {
            sidecar.logout()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spotify 가사 로그인"
        alert.informativeText = """
        로그인하지 않아도 가사는 LRCLIB에서 찾아옵니다. 로그인하면 Spotify 앱이 보여 주는 가사를 먼저 쓰고, 재생 위치도 Spotify에서 바로 받아 더 정확히 맞춥니다.

        Spotify 클라이언트로 로그인해 문서화되지 않은 방식으로 가사를 받아 오므로, Spotify 약관상 회색 지대에 있고 언제든 동작하지 않게 될 수 있습니다. 다시 쓸 수 있는 로그인 정보가 이 Mac에 저장됩니다(로그아웃하면 지워집니다).

        계속하면 브라우저에서 Spotify 로그인 화면이 열립니다.
        """
        alert.addButton(withTitle: "로그인")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let result = await sidecar.login()
            guard result != .cancelled else { return }
            if result == .loggedIn { updateLyrics() }
            // Task 안에서 runModal을 부르면 알림창이 떠 있는 동안 다른 MainActor 작업이 멈춘다(handleURLEvent 참고).
            RunLoop.main.perform {
                MainActor.assumeIsolated { self.showLyricsLoginResult(succeeded: result == .loggedIn) }
            }
        }
    }

    private func showLyricsLoginResult(succeeded: Bool) {
        let alert = NSAlert()
        if succeeded {
            alert.messageText = "Spotify 가사에 로그인했습니다"
            alert.informativeText = showsFloatingLyrics || showsMenuBarLyrics
                ? "다음 곡부터 Spotify의 가사를 먼저 씁니다. 브라우저 탭은 닫아도 됩니다."
                : "메뉴에서 가사 표시를 켜면 Spotify의 가사를 먼저 씁니다. 브라우저 탭은 닫아도 됩니다."
        } else {
            alert.messageText = "Spotify 가사 로그인에 실패했습니다"
            alert.informativeText = "브라우저에서 로그인을 끝내지 않았거나 Spotify에 연결하지 못했습니다. 다시 시도하세요."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        if menuItem.action == #selector(toggleFloatingLyrics(_:)) {
            menuItem.state = showsFloatingLyrics ? .on : .off
        }
        if menuItem.action == #selector(toggleHideLyricsOnHover(_:)) {
            menuItem.state = hidesLyricsOnHover ? .on : .off
            // 화면에 가사를 띄우지 않으면 고를 것이 없다.
            return showsFloatingLyrics
        }
        if menuItem.action == #selector(toggleHideLyricsWhileTyping(_:)) {
            // 켜 두었지만 손쉬운 사용 권한이 아직 없으면 동작하지 않는다.
            menuItem.state = !hidesLyricsWhileTyping ? .off : TypingWatcher.isTrusted ? .on : .mixed
            return showsFloatingLyrics
        }
        if menuItem.action == #selector(selectLyricsBackground(_:)) {
            menuItem.state = menuItem.representedObject as? String == lyricsBackgroundStyle?.rawValue ? .on : .off
            return showsFloatingLyrics
        }
        if menuItem.action == #selector(selectLyricsPronunciation(_:)) {
            menuItem.state = menuItem.representedObject as? String == lyricsPronunciationStyle?.rawValue ? .on : .off
            return showsFloatingLyrics
        }
        if menuItem.action == #selector(selectLyricsTranslation(_:)) {
            menuItem.state = menuItem.representedObject as? String == lyricsTranslationLanguage ? .on : .off
            return showsFloatingLyrics
        }
        if menuItem.action == #selector(downloadTranslationLanguage(_:)) {
            // 지금 곡의 가사를 옮기는 데 없는 언어가 있을 때만 보인다.
            let source = showsFloatingLyrics ? lyrics.languageToDownload : nil
            menuItem.isHidden = source == nil
            if let source {
                menuItem.title = "\(LyricsTranslator.name(of: source, inKorean: true)) 번역 언어 내려받기…"
            }
            // 바로 위 구분선도 함께 숨긴다.
            if let menu = menuItem.menu, menu.index(of: menuItem) > 0 {
                menu.item(at: menu.index(of: menuItem) - 1)?.isHidden = source == nil
            }
            return source != nil
        }
        if menuItem.action == #selector(toggleMenuBarLyrics(_:)) {
            menuItem.state = showsMenuBarLyrics ? .on : .off
        }
        if menuItem.action == #selector(toggleLyricsLogin(_:)) {
            // Rust 없이 빌드한 앱에는 사이드카가 없다. 그때는 LRCLIB만 쓴다.
            menuItem.isHidden = !sidecar.isAvailable
            menuItem.title = sidecar.isLoggedIn ? "Spotify 가사 로그아웃" : "Spotify 가사 로그인…"
            menuItem.state = sidecar.isLoggedIn ? .on : .off
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
