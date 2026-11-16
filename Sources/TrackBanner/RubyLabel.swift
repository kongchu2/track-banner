import AppKit

/// 낱말마다 발음을 위에 작게 얹어(루비) 그리는 라벨.
/// NSTextField는 루비를 그리지 못하고, Core Text의 루비는 발음을 글자 폭에 맞춰 벌리거나 이웃과 겹쳐 그려서 읽기 어렵다.
/// 그래서 낱말을 한 칸씩 직접 놓는다: 칸의 너비는 글자와 발음 중 넓은 쪽이고, 둘 다 칸 가운데에 둔다.
final class RubyLabel: NSView {
    private let font: NSFont
    private let rubyFont: NSFont
    /// 발음을 얹은 낱말 사이의 틈. 없으면 이웃한 발음끼리 붙어 한 낱말처럼 읽힌다.
    private static let wordGap: CGFloat = 5
    /// 발음과 글자 사이. 두 글꼴의 줄 높이에 이미 여백이 있어서 조금 당긴다.
    private static let rubyGap: CGFloat = -3

    var segments: [LyricsRomanizer.RubySegment] = [] {
        didSet { needsDisplay = true }
    }

    init(font: NSFont) {
        self.font = font
        rubyFont = NSFont.systemFont(ofSize: (font.pointSize * 0.6).rounded(), weight: .medium)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 한 낱말이 차지하는 칸.
    private struct Cell {
        let text: NSAttributedString
        let reading: NSAttributedString?
        let textWidth: CGFloat
        let readingWidth: CGFloat
        /// 뒤에 두는 틈까지 넣은 너비.
        let width: CGFloat
    }

    private var textHeight: CGFloat { ceil(font.ascender - font.descender) }
    private var rubyHeight: CGFloat { ceil(rubyFont.ascender - rubyFont.descender) }
    private var rowHeight: CGFloat { rubyHeight + Self.rubyGap + textHeight }

    private func cells() -> [Cell] {
        segments.map { segment in
            let text = NSAttributedString(string: segment.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let reading = segment.reading.map {
                NSAttributedString(string: $0, attributes: [.font: rubyFont, .foregroundColor: NSColor.secondaryLabelColor])
            }
            let textWidth = ceil(text.size().width)
            let readingWidth = ceil(reading?.size().width ?? 0)
            let gap = reading == nil ? 0 : Self.wordGap
            return Cell(text: text, reading: reading, textWidth: textWidth, readingWidth: readingWidth, width: max(textWidth, readingWidth) + gap)
        }
    }

    /// 칸을 `width`를 넘지 않게 줄로 나눈다.
    private func rows(of cells: [Cell], maxWidth width: CGFloat) -> [[Cell]] {
        var rows: [[Cell]] = [[]]
        var used: CGFloat = 0
        for cell in cells {
            // 줄 끝에 오는 낱말은 뒤의 틈이 필요 없다. 그 틈 때문에 다음 줄로 넘기지 않는다.
            let needed = cell.width - (cell.reading == nil ? 0 : Self.wordGap)
            if used + needed > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append(cell)
            used += cell.width
        }
        return rows
    }

    private func width(of row: [Cell]) -> CGFloat {
        // 줄 끝 낱말 뒤의 틈은 세지 않는다.
        row.reduce(0) { $0 + $1.width } - (row.last?.reading == nil ? 0 : Self.wordGap)
    }

    /// `width` 안에 줄바꿈해 그릴 때 필요한 크기.
    func fittingSize(maxWidth width: CGFloat) -> NSSize {
        let rows = rows(of: cells(), maxWidth: width)
        return NSSize(width: ceil(rows.map(self.width).max() ?? 0), height: rowHeight * CGFloat(rows.count))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rows = rows(of: cells(), maxWidth: bounds.width + 1)
        var top = bounds.maxY
        for row in rows {
            // 줄마다 가운데로 맞춘다.
            var x = bounds.midX - width(of: row) / 2
            for cell in row {
                let column = cell.width - (cell.reading == nil ? 0 : Self.wordGap)
                cell.reading?.draw(at: NSPoint(x: x + (column - cell.readingWidth) / 2, y: top - rubyHeight))
                cell.text.draw(at: NSPoint(x: x + (column - cell.textWidth) / 2, y: top - rowHeight))
                x += cell.width
            }
            top -= rowHeight
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
