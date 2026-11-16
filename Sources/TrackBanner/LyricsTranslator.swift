import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// 가사를 다른 언어로 옮긴다. Apple의 기기 내 번역을 쓰므로 가사가 밖으로 나가지 않는다(macOS 15 이상).
@MainActor
final class LyricsTranslator {
    enum Outcome {
        /// 원문과 같은 순서, 같은 개수. 옮길 것이 없던 줄은 빈 문자열이다.
        case translated([String])
        /// 가사가 이미 그 언어다.
        case notNeeded
        /// 번역 언어를 내려받아야 한다. `source`는 가사의 언어(en, ja, zh-Hant, …).
        case needsDownload(source: String)
        /// 지금은 옮길 수 없다(지원하지 않는 언어 쌍, 오류). 나중에 다시 해 볼 수 있다.
        case unavailable
    }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 고를 수 있는 번역 언어: 시스템에 설정한 언어들과 영어.
    static var languages: [(id: String, name: String)] {
        var seen = Set<String>()
        return (Locale.preferredLanguages + ["en"]).compactMap { identifier in
            guard let code = Locale.Language(identifier: identifier).languageCode?.identifier,
                  seen.insert(code).inserted else { return nil }
            // 언어 이름은 그 언어로 적는다(日本語, 한국어, English).
            let name = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
            return (code, name)
        }
    }

    /// 언어 이름을 그 언어로(日本語, 한국어) 또는 메뉴에 쓰는 한국어로.
    static func name(of language: String, inKorean: Bool = false) -> String {
        let locale = Locale(identifier: inKorean ? "ko" : language)
        return locale.localizedString(forIdentifier: language) ?? language
    }

    /// 내려받기를 시작한 언어가 준비됐을 때. 기다리던 번역을 다시 시도하면 된다.
    var onLanguagesInstalled: (() -> Void)?

    /// 번역은 한 번에 하나씩 한다.
    private var queue: Task<Outcome, Never>?
    /// `TranslationHost`. macOS 15부터 있는 타입이라 그대로는 적을 수 없다.
    private var hostStorage: AnyObject?
    private var installWatch: Task<Void, Never>?

    /// 가사를 옮긴다. 창을 띄우지 않는다: 언어가 없으면 `.needsDownload`로 알리기만 한다.
    func translate(_ lines: [String], to target: String) async -> Outcome {
        guard #available(macOS 15.0, *) else { return .unavailable }
        let previous = queue
        let task = Task { [weak self] () -> Outcome in
            _ = await previous?.value
            guard let self else { return .unavailable }
            return await self.run(lines, to: target)
        }
        queue = task
        return await task.value
    }

    @available(macOS 15.0, *)
    private func run(_ lines: [String], to targetID: String) async -> Outcome {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.joined(separator: "\n"))
        guard let detected = recognizer.dominantLanguage else { return .unavailable }
        var source = Locale.Language(identifier: detected.rawValue)
        let target = Locale.Language(identifier: targetID)
        if source.languageCode == target.languageCode { return .notNeeded }

        /// 번역기에 넘기기 전에 글자를 바꿔야 하면 그 변환.
        var conversion: StringTransform?
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported:
            // 중국어는 간체와 번체를 따로 내려받는다. 한쪽만 있으면 글자를 그쪽으로 바꿔서 옮긴다.
            let other: (id: String, transform: String)? = detected == .simplifiedChinese ? ("zh-Hant", "Hans-Hant")
                : detected == .traditionalChinese ? ("zh-Hans", "Hant-Hans") : nil
            guard let other, await LanguageAvailability().status(from: .init(identifier: other.id), to: target) == .installed
            else { return .needsDownload(source: detected.rawValue) }
            source = Locale.Language(identifier: other.id)
            conversion = StringTransform(other.transform)
        default: return .unavailable
        }

        // 같은 줄이 되풀이되는 가사가 많다. 한 번씩만 옮긴다.
        let unique = Array(Set(lines.filter { !$0.isEmpty }))
        let requests = unique.enumerated().map { index, line in
            let text = conversion.flatMap { line.applyingTransform($0, reverse: false) } ?? line
            return TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        var translated: [String: String]?
        await host().run(source: source, target: target, showsDialog: false) { session in
            guard let responses = try? await session.translations(from: requests) else { return }
            var result: [String: String] = [:]
            for response in responses {
                guard let index = response.clientIdentifier.flatMap(Int.init), unique.indices.contains(index) else { continue }
                result[unique[index]] = response.targetText
            }
            translated = result
        }
        guard let translated else { return .unavailable }
        return .translated(lines.map { line in
            guard let text = translated[line]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
            // 옮겨도 그대로인 줄(다른 언어가 섞인 줄, 감탄사)은 되풀이해 보여 주지 않는다.
            return text.caseInsensitiveCompare(line) == .orderedSame ? "" : text
        })
    }

    /// 시스템의 "번역 언어 내려받기" 창을 띄운다. 사용자가 메뉴에서 고른 때에만 부른다.
    /// 내려받기는 창을 닫은 뒤에도 뒤에서 이어지므로, 끝날 때까지 지켜보다가 `onLanguagesInstalled`로 알린다.
    func download(source sourceID: String, target targetID: String) async {
        guard #available(macOS 15.0, *) else { return }
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
        await host().run(source: source, target: target, showsDialog: true) { session in
            try? await session.prepareTranslation()
        }
        installWatch?.cancel()
        installWatch = Task { [weak self] in
            // 큰 언어는 몇 분 걸린다. 20분까지 지켜본다.
            for _ in 0..<400 {
                if await LanguageAvailability().status(from: source, to: target) == .installed {
                    if !Task.isCancelled { self?.onLanguagesInstalled?() }
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    @available(macOS 15.0, *)
    private func host() -> TranslationHost {
        if let host = hostStorage as? TranslationHost { return host }
        let host = TranslationHost()
        hostStorage = host
        return host
    }
}

/// 번역 세션은 SwiftUI 뷰의 `translationTask` 안에서만 얻을 수 있다. 그 뷰를 얹어 둘 창을 들고 있는다.
/// 창 자체는 보이지 않는다. 언어를 내려받을 때 시스템이 띄우는 창이 이 창에 붙어 나올 뿐이다.
@available(macOS 15.0, *)
@MainActor
private final class TranslationHost {
    /// 테두리 없는 창은 기본으로는 키 창이 될 수 없어서, 붙어 나온 내려받기 창의 버튼이 눌리지 않는다.
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private var window: NSWindow?

    func run(
        source: Locale.Language, target: Locale.Language, showsDialog: Bool,
        job: @escaping @MainActor (TranslationSession) async -> Void
    ) async {
        let window = self.window ?? makeWindow()
        self.window = window
        var finish: (() -> Void)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var isFinished = false
            finish = {
                guard !isFinished else { return }
                isFinished = true
                continuation.resume()
            }
            let view = TranslationJobView(configuration: .init(source: source, target: target)) { session in
                await job(session)
                finish?()
            }
            window.contentView = NSHostingView(rootView: view)
            if showsDialog {
                // 내려받기 창은 이 창 위쪽에 붙어 나온다. 화면 가운데쯤에 오도록 조금 위에 둔다.
                let screen = NSScreen.main?.visibleFrame ?? .zero
                window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY + 220))
                window.ignoresMouseEvents = false
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
            }
            // 뷰가 일을 시작하지 못하면 영영 끝나지 않는다. 내려받기 창은 사용자가 닫을 때까지 떠 있으니 넉넉히 기다린다.
            let timeout: TimeInterval = showsDialog ? 30 * 60 : 60
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish?()
            }
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    private func makeWindow() -> NSWindow {
        let window = Window(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        return window
    }
}

@available(macOS 15.0, *)
private struct TranslationJobView: View {
    let configuration: TranslationSession.Configuration
    let job: @MainActor (TranslationSession) async -> Void

    var body: some View {
        Color.clear.translationTask(configuration) { session in await job(session) }
    }
}
