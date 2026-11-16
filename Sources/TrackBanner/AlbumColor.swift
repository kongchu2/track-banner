import AppKit

/// 앨범 커버에서 가장 두드러진 선명한 색을 찾는다.
enum AlbumColor {
    /// 커버의 대표 색상(hue, 0–1)과 그 채도. 흑백에 가까운 커버면 nil.
    static func accent(of image: NSImage) -> (hue: CGFloat, saturation: CGFloat)? {
        let side = 32
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // 색상을 18칸으로 나눠, 선명하고 너무 어둡거나 밝지 않은 픽셀일수록 무겁게 센다.
        struct Bucket { var weight = 0.0, x = 0.0, y = 0.0, saturation = 0.0 }
        var buckets = [Bucket](repeating: Bucket(), count: 18)
        for i in 0..<(side * side) {
            let (h, s, l) = hsl(Double(pixels[i * 4]) / 255, Double(pixels[i * 4 + 1]) / 255, Double(pixels[i * 4 + 2]) / 255)
            if s < 0.18 || l < 0.1 || l > 0.92 { continue }
            let weight = s * max(0, 1 - abs(l - 0.5) * 1.6)
            let index = Int(h * 18) % 18
            buckets[index].weight += weight
            // 칸 안에서의 평균 색상은 각도로 구한다(0과 1이 이어져 있다).
            buckets[index].x += cos(h * 2 * .pi) * weight
            buckets[index].y += sin(h * 2 * .pi) * weight
            buckets[index].saturation += s * weight
        }
        guard let best = buckets.max(by: { $0.weight < $1.weight }), best.weight >= Double(side * side) * 0.012 else {
            return nil
        }
        var hue = atan2(best.y, best.x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return (CGFloat(hue), CGFloat(best.saturation / best.weight))
    }

    /// HSL로 고른 색. 밝기를 정해 두고 색상만 바꿔 쓰기에는 HSB보다 HSL이 고르다.
    static func color(hue: CGFloat, saturation s: CGFloat, lightness l: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let v = l + s * min(l, 1 - l)
        return NSColor(hue: hue, saturation: v == 0 ? 0 : 2 * (1 - l / v), brightness: v, alpha: alpha)
    }

    private static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        let d = high - low
        if d == 0 { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h = high == r ? ((g - b) / d).truncatingRemainder(dividingBy: 6) : high == g ? (b - r) / d + 2 : (r - g) / d + 4
        h /= 6
        return (h < 0 ? h + 1 : h, s, l)
    }
}
