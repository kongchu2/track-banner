import Foundation

/// 가사의 발음을 로마자로 적는다: 일본어는 로마지, 중국어는 병음, 그 밖의 문자는 로마자 옮겨 적기.
/// macOS에 들어 있는 형태소 분석과 문자 변환만 쓰므로 내려받을 것이 없고 바로 끝난다.
/// 한글은 적지 않는다(이 앱은 한국어로 쓰는 앱이다).
enum LyricsRomanizer {
    /// 원문의 한 조각과 그 위에 얹을 발음. 발음이 없는 조각(문장 부호, 이미 로마자인 낱말)은 nil.
    struct RubySegment: Equatable {
        let text: String
        let reading: String?
    }

    private enum Script {
        case japanese, chinese, other
    }

    /// `lines`와 같은 순서, 같은 개수. 적을 발음이 없는 줄은 빈 문자열이고, 가사 전체에 적을 것이 없으면 nil.
    static func romanize(_ lines: [String]) -> [String]? {
        let script = script(of: lines)
        let out = lines.map { line -> String in
            guard line.unicodeScalars.contains(where: needsRomanizing) else { return "" }
            let text: String
            switch script {
            case .japanese: text = japanese(line)
            case .chinese: text = words(in: line, locale: "zh").map { $0.latin ?? $0.text }.joined(separator: " ")
            case .other: text = line.applyingTransform(.toLatin, reverse: false) ?? ""
            }
            return text.caseInsensitiveCompare(line) == .orderedSame ? "" : text
        }
        return out.contains { !$0.isEmpty } ? out : nil
    }

    /// 조사로 쓰일 때 적힌 글자와 다르게 읽는 것들.
    private static let particleReadings = ["は": "wa", "を": "o", "へ": "e"]
    /// 한 글자 조사. 이 뒤에 오는 말은 앞말에 붙여 쓰지 않는다.
    private static let particles: Set<String> = ["は", "が", "を", "に", "へ", "と", "も", "の", "で", "や", "か", "ね", "よ"]
    /// 형태소 분석은 활용 어미를 따로 떼어 낸다(呼ん·で, 信じ·ない). 앞말에 붙여 써야 읽기 쉽다.
    private static let suffixes: Set<String> = ["て", "た", "だ", "ば", "たい", "ない", "ます", "まし", "ませ", "たり", "ちゃ", "じゃ"]

    private static func japanese(_ line: String) -> String {
        var out = ""
        for word in japaneseWords(in: line) {
            if !out.isEmpty && !word.attaches { out += " " }
            out += word.reading ?? word.text
        }
        return out
    }

    /// 일본어 줄의 낱말과 읽기. `attaches`면 앞말에 붙여 쓴다.
    private static func japaneseWords(in line: String) -> [(text: String, reading: String?, attaches: Bool, range: NSRange)] {
        let words = words(in: line, locale: "ja")
        var out: [(text: String, reading: String?, attaches: Bool, range: NSRange)] = []
        /// 앞 조각이 촉음(っ)으로 끝났다: 이 조각은 붙여 쓴다(だっ·た → datta).
        var afterSokuon = false
        for (index, word) in words.enumerated() {
            var reading = word.latin.map { particleReadings[word.text] ?? $0 }
            let previous = index > 0 ? words[index - 1].text : ""
            let attaches = afterSokuon
                || (suffixes.contains(word.text) && !previous.isEmpty && !particles.contains(previous))
                || (word.text == "で" && previous.hasSuffix("ん"))
            // 시스템은 낱말 끝의 촉음을 "~tsu"로 적는다. 실제로는 다음 소리의 첫 자음을 겹쳐 읽는다.
            afterSokuon = reading?.hasSuffix("~tsu") == true
            if afterSokuon {
                reading?.removeLast(4)
                let next = index + 1 < words.count ? (words[index + 1].latin ?? words[index + 1].text) : ""
                if let first = next.first, first.isLetter, first.isASCII, !"aiueo".contains(first) { reading?.append(first) }
            }
            out.append((word.text, reading, attaches, word.range))
        }
        return out
    }

    /// 줄을 낱말로 나누고, 낱말마다 시스템이 아는 로마자 읽기를 붙인다. 문장 부호는 빠진다.
    private static func words(in line: String, locale: String?) -> [(text: String, latin: String?, range: NSRange)] {
        let string = line as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRangeMake(0, CFStringGetLength(string)),
            kCFStringTokenizerUnitWord, locale.map { Locale(identifier: $0) as CFLocale }
        )
        var words: [(String, String?, NSRange)] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let text = CFStringCreateWithSubstring(nil, string, range) as String
            // 이미 로마자인 낱말(가사에 섞인 영어)은 그대로 둔다.
            let latin = text.unicodeScalars.contains(where: needsRomanizing)
                ? CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                : nil
            words.append((text, latin, NSRange(location: range.location, length: range.length)))
        }
        return words
    }

    /// 글자 위에 얹을 발음. 줄마다 원문을 낱말로 나눈 조각들이고, 이어 붙이면 원문 그대로다.
    /// 얹을 발음이 없는 줄은 빈 배열이고, 가사 전체에 얹을 것이 없으면 nil.
    static func ruby(_ lines: [String]) -> [[RubySegment]]? {
        let script = script(of: lines)
        let out = lines.map { line -> [RubySegment] in
            guard line.unicodeScalars.contains(where: needsRomanizing) else { return [] }
            let words: [(range: NSRange, reading: String?)]
            switch script {
            case .japanese: words = japaneseWords(in: line).map { ($0.range, $0.reading) }
            case .chinese: words = self.words(in: line, locale: "zh").map { ($0.range, $0.latin) }
            case .other:
                words = self.words(in: line, locale: nil).map { word in
                    let needs = word.text.unicodeScalars.contains(where: needsRomanizing)
                    return (word.range, needs ? word.text.applyingTransform(.toLatin, reverse: false) : nil)
                }
            }
            // 낱말 사이의 공백과 문장 부호도 빠뜨리지 않고 그대로 잇는다.
            let text = line as NSString
            var segments: [RubySegment] = []
            var cursor = 0
            for word in words {
                if word.range.location > cursor {
                    segments.append(RubySegment(text: text.substring(with: NSRange(location: cursor, length: word.range.location - cursor)), reading: nil))
                }
                segments.append(RubySegment(text: text.substring(with: word.range), reading: word.reading))
                cursor = word.range.location + word.range.length
            }
            if cursor < text.length { segments.append(RubySegment(text: text.substring(from: cursor), reading: nil)) }
            return segments.contains { $0.reading != nil } ? segments : []
        }
        return out.contains { !$0.isEmpty } ? out : nil
    }

    private static func script(of lines: [String]) -> Script {
        // 가나가 한 글자라도 있으면 일본어다(한자만으로는 중국어와 가를 수 없다). 영어가 많이 섞인 일본어 가사도 놓치지 않는다.
        let all = lines.joined()
        return all.unicodeScalars.contains(where: isKana) ? .japanese
            : all.unicodeScalars.contains(where: isHan) ? .chinese : .other
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
            || (0x3130...0x318F).contains(scalar.value)
    }

    /// 로마자도 한글도 아닌 글자.
    private static func needsRomanizing(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic, !isHangul(scalar) else { return false }
        // 라틴 문자는 U+024F까지와 확장 영역(U+1E00–U+1EFF)에 있다.
        return !(scalar.value <= 0x024F || (0x1E00...0x1EFF).contains(scalar.value))
    }
}
