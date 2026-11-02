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
