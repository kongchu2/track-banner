import Foundation

/// 재생 중인 곡의 가사를 가져와, 재생 위치에 맞춰 지금 부르는 줄을 알려 준다.
/// 시계를 주기적으로 들여다보지 않고, 다음 줄이 시작하는 시각에 맞춰 한 번씩만 깨어난다.
@MainActor
final class LyricsController {
    /// 재생 위치를 알려 주는 곳. 뒤쪽일수록 정확해서, 같은 곡에 대해 여럿이 알리면 뒤쪽 것을 쓴다.
    enum Source: Int, CaseIterable {
        /// Web API 폴링. 몇 초에 한 번, 1초쯤 어긋날 수 있다.
        case web
        /// 공식 클라이언트의 알림과 AppleScript.
        case client
        /// Spotify Connect(사이드카). 재생·탐색·일시정지가 일어나는 즉시 온다.
        case connect

        /// 새로 알려 온 위치가 지금 짐작하는 위치와 이만큼(ms)도 다르지 않으면 무시한다.
        /// 폴링 값의 작은 흔들림 때문에 줄이 앞뒤로 오가지 않게 한다.
        var tolerance: Double {
            switch self {
            case .web: return 750
            case .client: return 200
            case .connect: return 50
            }
        }
    }

    /// 줄을 조금 일찍 바꾼다. 화면에서 줄이 바뀌는 데 걸리는 시간만큼이다.
    private static let leadMs: Double = 150
    /// 공식 클라이언트는 탐색해도 알려 주지 않을 수 있어서 이 간격으로 위치를 다시 묻는다.
    private static let clientResyncInterval: TimeInterval = 10

    /// 지금 부르는 줄과, 켜 두었고 적을 것이 있으면 그 발음과 번역.
    struct Line: Equatable {
        let text: String
        /// 로마자로 적은 발음(가사 아래에 적을 때).
        var pronunciation: String?
        /// 원문을 낱말로 나눈 조각과 그 위에 얹을 발음(글자 위에 적을 때).
        var ruby: [LyricsRomanizer.RubySegment]?
        var translation: String?
    }

    /// 보여 줄 줄이 바뀌었을 때. 가사가 없는 곡, 첫 줄이 나오기 전, 간주에서는 nil이다.
    var onLine: ((Line?) -> Void)?
    /// 공식 클라이언트에 지금 재생 위치를 묻는다(AppleScript). 재생 중이 아니면 nil.
    var clientPosition: (() async -> PlaybackPosition?)?

    /// 꺼져 있으면 가사를 찾지도, 위치를 묻지도 않는다.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            reload()
        }
    }

    /// 가사를 옮길 언어(ko, ja, …). nil이면 번역하지 않는다.
    var translationLanguage: String? {
        didSet {
            guard translationLanguage != oldValue else { return }
            loadTranslation()
        }
    }

    enum PronunciationStyle: String {
        /// 가사 아래에 한 줄로.
        case below
        /// 글자 위에 작게.
        case above
    }

    /// 가사의 발음을 로마자로 함께 알린다. nil이면 알리지 않는다.
    var pronunciationStyle: PronunciationStyle? {
        didSet {
            guard pronunciationStyle != oldValue else { return }
            loadPronunciation()
            update()
        }
    }

    private let store: LyricsStore
    private var track: Track?
    private var lines: [LyricLine]?
    /// `lines`와 같은 순서로 옮긴 것. 번역하지 않거나 아직 옮기는 중이면 nil.
    private var translations: [String]?
    /// `lines`와 같은 순서로 적은 발음. 켜지 않았거나 적을 것이 없는 가사면 nil.
    private var pronunciations: [String]?
    /// `lines`와 같은 순서로, 글자 위에 얹을 발음.
    private var rubies: [[LyricsRomanizer.RubySegment]]?
    private var translationTask: Task<Void, Never>?
    /// 지금 곡을 번역하려면 내려받아야 하는 언어(가사의 언어). 필요 없으면 nil.
    private(set) var languageToDownload: String?
    /// 지금 곡의 번역에 내려받을 언어가 있다는 것을 알았을 때.
    var onLanguageNeeded: ((String) -> Void)?
    /// 번역 자리에 잠깐 보여 주는 안내와 그것을 거두는 시각. 번역이 왜 없는지, 어디서 내려받는지 알린다.
    private var notice: (text: String, until: Date)?
    /// 이번 실행에서 이미 안내한 언어. 그 언어의 곡마다 되풀이하지 않는다.
    private var noticedLanguages: Set<String> = []
    private static let noticeDuration: TimeInterval = 12
    private var positions: [Source: PlaybackPosition] = [:]
    private var line: Line?
    private var loadTask: Task<Void, Never>?
    private var lineTimer: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?

    init(store: LyricsStore) {
        self.store = store
    }

    /// 재생 중인 곡. 일시정지·정지면 nil.
    func setTrack(_ track: Track?) {
        guard track?.id != self.track?.id else { return }
        self.track = track
        // 멈춰 있던 동안의 위치는 다시 재생할 때 맞지 않는다.
        if track == nil { positions.removeAll() }
        reload()
    }

    /// 한 소스가 재생 위치를 알려 왔다.
    func report(_ position: PlaybackPosition, from source: Source) {
        if let known = positions[source], known.trackID == position.trackID,
           abs(known.positionMs(at: position.at) - position.positionMs) < source.tolerance {
            return
        }
        positions[source] = position
        update()
    }

    /// 그 소스가 더는 재생 중이 아니다.
    func clearPosition(from source: Source) {
        guard positions.removeValue(forKey: source) != nil else { return }
        update()
    }

    private func reload() {
        loadTask?.cancel()
        resyncTask?.cancel()
        translationTask?.cancel()
        lines = nil
        translations = nil
        pronunciations = nil
        rubies = nil
        languageToDownload = nil
        notice = nil
        update()
        guard isEnabled, let track, track.spotifyTrackID != nil else { return }
        loadTask = Task { [weak self, store] in
            let lines = await store.lines(for: track)
            guard let self, !Task.isCancelled, self.track?.id == track.id else { return }
            self.lines = lines
            self.loadPronunciation()
            self.update()
            if lines != nil {
                self.startClientResync(for: track)
                self.loadTranslation()
            }
        }
    }

    /// 발음은 기기 안에서 바로 적을 수 있어서 기다릴 것도 남겨 둘 것도 없다.
    private func loadPronunciation() {
        let texts = lines?.map(\.text)
        pronunciations = pronunciationStyle == .below ? texts.flatMap(LyricsRomanizer.romanize) : nil
        rubies = pronunciationStyle == .above ? texts.flatMap(LyricsRomanizer.ruby) : nil
    }

    /// 지금 가사의 번역을 가져온다. 오는 동안은 원문만 보여 준다. 번역 언어를 내려받은 뒤에도 부른다.
    func loadTranslation() {
        translationTask?.cancel()
        translations = nil
        languageToDownload = nil
        notice = nil
        defer { update() }
        guard let translationLanguage, let track, let lines else { return }
        translationTask = Task { [weak self, store] in
            let result = await store.translation(of: lines, for: track, to: translationLanguage)
            guard let self, !Task.isCancelled, self.track?.id == track.id, self.lines == lines,
                  self.translationLanguage == translationLanguage
            else { return }
            switch result {
            case .ready(let translations):
                guard translations?.count == lines.count else { return }
                self.translations = translations
                self.update()
            case .needsDownload(let source):
                self.languageToDownload = source
                if self.noticedLanguages.insert(source).inserted {
                    let name = LyricsTranslator.name(of: source, inKorean: true)
                    self.notice = ("\(name) 번역 언어가 없습니다 · 메뉴의 가사 번역에서 내려받기", Date().addingTimeInterval(Self.noticeDuration))
                    self.update()
                }
                self.onLanguageNeeded?(source)
            }
        }
    }

    /// Connect가 위치를 알려 주지 않는 동안, 공식 클라이언트에 주기적으로 위치를 묻는다.
    private func startClientResync(for track: Track) {
        guard let clientPosition else { return }
        resyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.track?.id == track.id else { return }
                if self.positions[.connect]?.trackID != track.id {
                    if let position = await clientPosition(), !Task.isCancelled, self.track?.id == track.id {
                        self.report(position, from: .client)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.clientResyncInterval * 1_000_000_000))
            }
        }
    }

    /// 이 곡에 대해 가장 믿을 만한 재생 위치.
    private var position: PlaybackPosition? {
        guard let track else { return nil }
        return Source.allCases.reversed().lazy.compactMap { self.positions[$0] }.first { $0.trackID == track.id }
    }

    /// 지금 줄을 다시 계산해 알리고, 다음 줄이 시작할 때 깨어나도록 맞춘다.
    private func update() {
        lineTimer?.cancel()
        guard let lines, let position else {
            emit(nil)
            return
        }
        let now = position.positionMs(at: Date()) + Self.leadMs
        let index = LyricsParser.activeIndex(in: lines, at: now)
        let text = index < 0 ? "" : lines[index].text
        func extra(_ texts: [String]?) -> String? {
            guard index >= 0, let text = texts?[index], !text.isEmpty else { return nil }
            return text
        }
        let notice = self.notice.flatMap { $0.until > Date() ? $0.text : nil }
        let ruby = index >= 0 ? rubies?[index] : nil
        emit(text.isEmpty ? nil : Line(
            text: text, pronunciation: extra(pronunciations), ruby: ruby?.isEmpty == false ? ruby : nil,
            translation: extra(translations) ?? notice
        ))
        guard index + 1 < lines.count else { return }
        let wait = max(20, Double(lines[index + 1].t) - now)
        lineTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func emit(_ line: Line?) {
        guard line != self.line else { return }
        self.line = line
        onLine?(line)
    }
}

extension PlaybackPosition {
    /// 계속 재생됐다고 보고 `date`에서의 위치(ms)를 짐작한다.
    func positionMs(at date: Date) -> Double {
        positionMs + date.timeIntervalSince(at) * 1000
    }
}
