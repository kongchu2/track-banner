import Foundation

/// 싱크 가사 한 줄. `text`가 비어 있으면 노래가 없는 구간(간주)이다.
struct LyricLine: Codable, Equatable {
    /// 줄이 시작하는 시각(ms).
    let t: Int
    let text: String
}

enum LyricsParser {
    /// LRC(`[01:23.45] 가사`) 형식. 시각이 없는 줄(`[ar:…]` 같은 머리말 포함)은 버린다.
    static func lrc(_ lrc: String) -> [LyricLine]? {
        var lines: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop(while: { $0 == " " || $0 == "\t" })
            // 같은 가사가 여러 번 나오면 시각을 여러 개 붙여 쓰기도 한다: [00:10.00][01:10.00] 가사
            var times: [Int] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]"),
                  let t = timestamp(rest[rest.index(after: rest.startIndex)..<close]) {
                times.append(t)
                rest = rest[rest.index(after: close)...]
            }
            let text = String(rest)
            lines.append(contentsOf: times.map { LyricLine(t: $0, text: text) })
        }
        return normalized(lines)
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss:xx`를 ms로.
    private static func timestamp(_ s: Substring) -> Int? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }),
              let minutes = Double(parts[0]), var seconds = Double(parts[1])
        else { return nil }
        if parts.count == 3 {
            guard let fraction = Double("0." + parts[2]) else { return nil }
            seconds += fraction
        }
        return Int(((minutes * 60 + seconds) * 1000).rounded())
    }

    /// Spotify 클라이언트가 쓰는 color-lyrics 응답. 줄 단위로 싱크된 가사가 아니면 nil.
    static func spotify(_ data: Data) -> [LyricLine]? {
        struct Response: Decodable {
            struct Lyrics: Decodable {
                struct Line: Decodable {
                    let startTimeMs: String?
                    let words: String?
                }
                let syncType: String?
                let lines: [Line]?
            }
            let lyrics: Lyrics?
        }
        guard let lyrics = (try? JSONDecoder().decode(Response.self, from: data))?.lyrics,
              let lines = lyrics.lines, lyrics.syncType != "UNSYNCED"
        else { return nil }
        let timed = lines.compactMap { line in
            line.startTimeMs.flatMap(Int.init).map { LyricLine(t: $0, text: line.words ?? "") }
        }
        // 싱크되지 않은 가사는 모든 줄의 시각이 0이다.
        guard timed.contains(where: { $0.t > 0 }) else { return nil }
        return normalized(timed)
    }

    /// 시간순으로 정리하고 간주 표시를 하나로 통일한다. 부를 가사가 한 줄도 없으면 nil.
    static func normalized(_ lines: [LyricLine]) -> [LyricLine]? {
        var out: [LyricLine] = []
        // 같은 시각의 줄은 원래 순서를 지킨다.
        let sorted = lines.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
        for (_, line) in sorted {
            var text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 간주를 ♪ 한 글자로 적는 가사가 많다.
            if text.allSatisfy({ $0 == "♪" || $0 == "♫" || $0 == "♬" || $0 == " " }) { text = "" }
            // 간주가 이어지면 한 번만 남긴다.
            if text.isEmpty, out.last?.text.isEmpty == true { continue }
            out.append(LyricLine(t: line.t, text: text))
        }
        return out.contains(where: { !$0.text.isEmpty }) ? out : nil
    }

    /// `positionMs`에 부르고 있는 줄의 위치. 첫 줄이 시작하기 전이면 -1.
    static func activeIndex(in lines: [LyricLine], at positionMs: Double) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if Double(lines[mid].t) <= positionMs { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}

extension Track {
    /// `spotify:track:<id>`의 id. 에피소드·로컬 파일·광고는 nil(가사를 찾지 않는다).
    var spotifyTrackID: String? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track",
              parts[2].count == 22, parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return String(parts[2])
    }
}
