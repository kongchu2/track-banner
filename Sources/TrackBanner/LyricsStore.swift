import Foundation
import os

/// 곡의 싱크 가사를 찾아 온다: Spotify 자체 가사(사이드카에 로그인했을 때) → LRCLIB.
/// 찾은 가사와 "없음"은 디스크에 남겨 같은 곡을 다시 묻지 않는다.
@MainActor
final class LyricsStore {
    struct Entry: Codable {
        /// nil이면 가사를 찾지 못한 곡이다.
        var lines: [LyricLine]?
        var fetchedAt: Date
        /// Spotify에 물어본 결과인지. 아니라면 사이드카에 로그인한 뒤 한 번 더 물어본다.
        var askedSpotify: Bool
        var translation: Translation?
    }

    struct Translation: Codable {
        /// 옮긴 언어(ko, ja, …).
        var target: String
        /// `Entry.lines`와 같은 순서, 같은 개수. 가사가 이미 그 언어라 옮길 필요가 없으면 nil.
        var lines: [String]?
    }

    /// 가사가 없던 곡은 이만큼 지나면 다시 찾아본다(나중에 등록됐을 수 있다).
    private static let missTTL: TimeInterval = 24 * 60 * 60
    /// 메모리에 들고 있는 곡 수. 같은 곡을 되풀이해 들을 때 디스크를 읽지 않으려는 것뿐이라 작아도 된다.
    private static let memoryLimit = 32

    /// 가사가 왜 안 나오는지 볼 수 있게 조회 결과를 남긴다:
    /// log stream --predicate 'subsystem == "com.kongchu2.trackbanner"'
    private static let log = Logger(subsystem: "com.kongchu2.trackbanner", category: "lyrics")

    private let sidecar: LyricsSidecar
    private let translator: LyricsTranslator
    private let directory: URL
    private var memory: [String: Entry] = [:]
    private var memoryOrder: [String] = []

    init(sidecar: LyricsSidecar, translator: LyricsTranslator) {
        self.sidecar = sidecar
        self.translator = translator
        directory = AppFiles.directory.appendingPathComponent("lyrics", isDirectory: true)
    }

    func lines(for track: Track) async -> [LyricLine]? {
        guard let id = track.spotifyTrackID else { return nil }
        let cached = memory[id] ?? read(id)
        /// 가사가 없다고 남겨 둔 지 오래돼 다시 찾아볼 때가 됐는지.
        var isStale = false
        if let cached {
            remember(id, cached)
            let spotifyPending = !cached.askedSpotify && sidecar.isRunning
            isStale = cached.lines == nil && Date().timeIntervalSince(cached.fetchedAt) > Self.missTTL
            if !spotifyPending && !isStale { return cached.lines }
        }

        var lines: [LyricLine]?
        var askedSpotify = false
        /// "없음"이라고 확실히 답을 들었는지. 물어보지 못한 것을 없음으로 남기면 하루 동안 다시 찾지 않게 된다.
        var isDefinite = true

        switch await sidecar.lyrics(trackID: id) {
        case .found(let data):
            askedSpotify = true
            lines = LyricsParser.spotify(data)
        case .none:
            askedSpotify = true
        case .unavailable:
            break
        }
        var source = lines == nil ? "none" : "spotify"
        var fetchedAt = Date()
        if lines == nil {
            if let cached, !isStale {
                // Spotify에만 다시 물어본 것이다. LRCLIB의 답은 전에 받아 둔 그대로 쓴다.
                lines = cached.lines
                fetchedAt = cached.fetchedAt
                if lines != nil { source = "kept from cache" }
            } else {
                do {
                    lines = try await LRCLIB.lines(for: track)
                    if lines != nil { source = "lrclib" }
                } catch {
                    isDefinite = false
                    source = "lrclib failed"
                }
            }
        }
        Self.log.info("""
        \(id, privacy: .public) "\(track.name, privacy: .public)" / "\(track.artist, privacy: .public)" / \
        "\(track.album, privacy: .public)" / \(track.durationMs ?? -1) ms → \(source, privacy: .public), \
        \(lines?.count ?? 0) lines, asked Spotify: \(askedSpotify)
        """)

        if lines != nil || isDefinite {
            // 가사가 그대로면 전에 해 둔 번역도 그대로 쓴다.
            let translation = lines == cached?.lines ? cached?.translation : nil
            let entry = Entry(lines: lines, fetchedAt: fetchedAt, askedSpotify: askedSpotify, translation: translation)
            remember(id, entry)
            write(id, entry)
        }
        return lines
    }

    enum TranslationResult {
        /// `lines`와 같은 순서, 같은 개수이고 옮길 것이 없던 줄은 빈 문자열이다. 가사가 이미 그 언어거나 옮길 수 없으면 nil.
        case ready([String]?)
        /// 가사의 언어(`source`)를 옮길 번역 언어를 내려받아야 한다.
        case needsDownload(source: String)
    }

    /// `lines`를 `target` 언어로 옮긴다.
    func translation(of lines: [LyricLine], for track: Track, to target: String) async -> TranslationResult {
        guard let id = track.spotifyTrackID else { return .ready(nil) }
        if let done = (memory[id] ?? read(id))?.translation, done.target == target,
           done.lines == nil || done.lines?.count == lines.count {
            return .ready(done.lines)
        }
        let translated: [String]?
        switch await translator.translate(lines.map(\.text), to: target) {
        case .translated(let texts): translated = texts
        case .notNeeded: translated = nil
        case .needsDownload(let source): return .needsDownload(source: source)
        case .unavailable: return .ready(nil)
        }
        // 옮기는 사이 가사가 바뀌었으면(Spotify 가사로 교체) 남기지 않는다.
        if var entry = memory[id] ?? read(id), entry.lines == lines {
            entry.translation = Translation(target: target, lines: translated)
            remember(id, entry)
            write(id, entry)
        }
        return .ready(translated)
    }

    private func remember(_ id: String, _ entry: Entry) {
        memory[id] = entry
        memoryOrder.removeAll { $0 == id }
        memoryOrder.append(id)
        if memoryOrder.count > Self.memoryLimit { memory[memoryOrder.removeFirst()] = nil }
    }

    private func read(_ id: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func write(_ id: String, _ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(id), options: .atomic)
    }

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }
}

enum AppFiles {
    /// ~/Library/Application Support/TrackBanner
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TrackBanner", isDirectory: true)
    }()
}
