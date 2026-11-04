import AppKit

/// 메뉴 막대 아이콘: 앱 아이콘과 같은 "앨범 커버 + 두 줄" 배너 모양.
/// 템플릿 이미지라 라이트/다크 메뉴 막대와 강조 상태에 맞게 색이 바뀐다.
enum StatusIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()

            // 배너 외곽선
            let banner = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 2.25, width: 17.5, height: 11.5),
                                      xRadius: 3.5, yRadius: 3.5)
            banner.lineWidth = 1.5
            banner.stroke()

            // 앨범 커버 (채움) + 음표를 뚫어 표시
            let art = NSRect(x: 3.5, y: 4.5, width: 7, height: 7)
            NSBezierPath(roundedRect: art, xRadius: 1.6, yRadius: 1.6).fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                // 음표 머리
                ctx.fillEllipse(in: CGRect(x: art.minX + 1.4, y: art.minY + 1.2, width: 2.6, height: 2.0))
                // 기둥
                ctx.fill(CGRect(x: art.minX + 3.3, y: art.minY + 2.1, width: 0.9, height: 3.9))
                // 깃발
                ctx.fill(CGRect(x: art.minX + 3.3, y: art.minY + 5.1, width: 2.3, height: 0.9))
                ctx.restoreGState()
            }

            // 제목 / 아티스트 줄
            NSBezierPath(roundedRect: NSRect(x: 12, y: 8.6, width: 4.6, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 5.6, width: 3.2, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Track Banner"
        return image
    }
}

extension StatusIcon {
    /// 앨범 커버를 메뉴 막대 크기의 둥근 정사각형으로 만든다.
    /// 커버 색을 그대로 보여야 하므로 템플릿 이미지가 아니다.
    /// 라이트/다크 어느 메뉴 막대에서도 보이도록 옅은 테두리를 두른다.
    static func make(artwork: NSImage) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: inset, xRadius: 3.5, yRadius: 3.5)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // 정사각형이 아닌 이미지는 가운데를 잘라 채운다.
            let src = artwork.size
            let edge = min(src.width, src.height)
            let from = NSRect(x: (src.width - edge) / 2, y: (src.height - edge) / 2, width: edge, height: edge)
            artwork.draw(in: inset, from: from, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.gray.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Track Banner"
        return image
    }
}

extension StatusIcon {
    /// 이미지 오른쪽에 투명 여백을 붙여 옆의 글자와 간격을 벌린다.
    static func padded(_ image: NSImage, trailing: CGFloat) -> NSImage {
        let size = NSSize(width: image.size.width + trailing, height: image.size.height)
        let result = NSImage(size: size, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: image.size))
            return true
        }
        result.isTemplate = image.isTemplate
        result.accessibilityDescription = image.accessibilityDescription
        return result
    }
}
