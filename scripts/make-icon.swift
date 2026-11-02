// 앱 아이콘 생성기: swift scripts/make-icon.swift
// Resources/AppIcon.icns 를 만든다.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: nil)!
}

func drawIcon(_ ctx: CGContext) {
    // 좌표계를 위가 +y 가 되도록 둔다 (CoreGraphics 기본)
    // macOS 아이콘 그리드: 824pt 둥근 사각형, 바깥 여백 100pt
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 바깥 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x101418))
    ctx.fillPath()
    ctx.restoreGState()

    // 배경: 짙은 초록 → 거의 검정
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x1F6B45), color(0x0E2A1F), color(0x0A0F0D)]),
                           start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // 은은한 빛
    ctx.drawRadialGradient(gradient([color(0x4BE38A, 0.35), color(0x4BE38A, 0)]),
                           startCenter: CGPoint(x: 700, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 700, y: 760), endRadius: 520, options: [])

    // 음표 실루엣 (배경 장식)
    drawNote(ctx, origin: CGPoint(x: 385, y: 165), scale: 0.7, fill: color(0xFFFFFF, 0.08))

    // 배너 카드
    let card = CGRect(x: 168, y: 520, width: 688, height: 236)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(color(0xF4F7F5, 0.94))
    ctx.fillPath()
    ctx.restoreGState()

    // 앨범 아트 자리
    let art = CGRect(x: card.minX + 34, y: card.minY + 34, width: 168, height: 168)
    let artPath = CGPath(roundedRect: art, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.addPath(artPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x5EF29A), color(0x1DB954), color(0x0F7A4A)]),
                           start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
    ctx.restoreGState()
    drawNote(ctx, origin: CGPoint(x: art.minX + 30, y: art.minY + 17), scale: 0.30, fill: color(0xFFFFFF, 0.95))

    // 제목 / 아티스트 줄
    let textX = art.maxX + 40
    func bar(_ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
        let r = CGRect(x: textX, y: y, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    bar(card.minY + 132, 380, 40, color(0x1A1F1C))
    bar(card.minY + 64, 260, 32, color(0x1A1F1C, 0.38))

    ctx.restoreGState()

    // 상단 하이라이트 테두리
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

// 8분음표 두 개를 이은 음표(♫). origin 기준 약 360x420 크기 × scale
func drawNote(_ ctx: CGContext, origin: CGPoint, scale s: CGFloat, fill: CGColor) {
    // 겹치는 부분이 진해지지 않도록 한 레이어로 그린 뒤 알파를 적용
    ctx.saveGState()
    ctx.setAlpha(fill.alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: s, y: s)
    ctx.setFillColor(fill.copy(alpha: 1)!)
    // 음표 머리
    for cx in [CGFloat(70), 290] {
        let cy: CGFloat = cx == 70 ? 60 : 110
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: 0.42)
        ctx.fillEllipse(in: CGRect(x: -72, y: -52, width: 144, height: 104))
        ctx.restoreGState()
    }
    // 기둥
    ctx.fill(CGRect(x: 112, y: 70, width: 34, height: 330))
    ctx.fill(CGRect(x: 332, y: 120, width: 34, height: 330))
    // 들보
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: 112, y: 340))
    beam.addLine(to: CGPoint(x: 366, y: 390))
    beam.addLine(to: CGPoint(x: 366, y: 450))
    beam.addLine(to: CGPoint(x: 112, y: 400))
    beam.closeSubpath()
    ctx.addPath(beam)
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx)
    gctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
