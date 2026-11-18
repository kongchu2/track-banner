import AppKit
import CoreImage

/// 지금 부르는 가사 한 줄을 띄워 두는 작은 플로팅 패널. 끌어서 옮길 수 있고 위치를 기억한다.
@MainActor
final class LyricsPanelController {
    private static let anchorKey = "LyricsPanelAnchor"
    private static let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
    private static let pronunciationFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let translationFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// 원문·발음·번역 사이.
    private static let lineGap: CGFloat = 1
    private static let padding = NSSize(width: 22, height: 11)
    private static let minWidth: CGFloat = 96
    /// 글자가 차지할 수 있는 가장 큰 너비. 화면이 좁으면 화면의 3/4까지만 쓴다. 넘치면 두 줄로 나눈다.
    private static let maxTextWidth: CGFloat = 960
    private static let cornerRadius: CGFloat = 20

    /// 마우스를 올리면 패널을 숨기고 클릭이 아래 창으로 지나가게 한다. 가사가 가린 곳을 보거나 누를 수 있다.
    /// 켜 둔 채로 패널을 옮기려면 ⌘를 누른 채 마우스를 올린다.
    var hidesOnHover = false {
        didSet { if !hidesOnHover { endHoverHiding() } }
    }

    /// 다른 앱에서 글자를 치고 있는 자리(화면 좌표). 패널이 그 자리를 가리면 치는 동안 숨긴다.
    var typingArea: NSRect? {
        didSet {
            guard let panel else { return }
            let hidden = overlapsTyping(panel.frame)
            guard hidden != isTypingHidden else { return }
            isTypingHidden = hidden
            applyHiding(duration: hidden ? 0.15 : 0.2)
        }
    }

    enum BackgroundStyle: String {
        /// 뒤의 화면이 비치는 유리.
        case clear
        /// 앨범 커버의 대표 색으로 배경을 물들인다.
        case color
        /// 흐리게 만든 앨범 커버를 깐다.
        case cover
    }

    /// 배경을 꾸미는 방식. nil이면 기본 유리 배경이다.
    var backgroundStyle: BackgroundStyle? {
        didSet { if backgroundStyle != oldValue { applyBackground() } }
    }
    /// 재생 중인 곡의 앨범 커버. 없으면 기본 배경으로 돌아간다.
    var artwork: NSImage? {
        didSet { if artwork !== oldValue { applyBackground() } }
    }

    private var panel: NSPanel?
    private var coverView: CoverBackgroundView?
    private var panelView: LyricsPanelView?
    /// 원문·발음·번역을 함께 담는 뷰. 패널 가운데에 떠 있다.
    private var content: NSView?
    /// 위에서부터 원문, 발음, 번역.
    private var labels: [NSTextField] = []
    /// 발음을 글자 위에 얹은 원문. 그렇게 보여 줄 때만 원문 라벨 대신 쓴다.
    private var rubyLabel: RubyLabel?
    private var shownLine: LyricsController.Line?
    private var isHiding = false
    /// 마우스가 올라와 있어 숨긴 상태. 패널은 그대로 떠 있고 보이지만 않는다.
    private var isHoverHidden = false
    private var hoverTimer: Timer?
    /// 글자를 치는 자리를 가려서 숨긴 상태.
    private var isTypingHidden = false
    /// 줄이 떠 있는 동안의 불투명도. 마우스나 글자 입력 때문에 숨겼으면 0이다.
    private var visibleAlpha: CGFloat { isHoverHidden || isTypingHidden ? 0 : 1 }

    /// 패널이 놓이는 기준점: 아래쪽 가운데. 줄 길이에 따라 패널은 이 점에서 양옆과 위로 늘어난다.
    private var anchor: NSPoint? {
        get {
            guard let saved = UserDefaults.standard.string(forKey: Self.anchorKey) else { return nil }
            let point = NSPointFromString(saved)
            // 그 자리를 보여 주던 모니터가 없어졌으면 기본 위치로 돌아간다.
            return NSScreen.screens.contains { $0.frame.contains(point) } ? point : nil
        }
        set { UserDefaults.standard.set(newValue.map(NSStringFromPoint), forKey: Self.anchorKey) }
    }

    private var defaultAnchor: NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: screen.midX, y: screen.minY + 72)
    }

    /// 줄을 보여 준다. nil이면 숨긴다. 발음과 번역이 있으면 원문 아래에 조금 작게, 그 순서로 붙인다.
    func show(_ line: LyricsController.Line?) {
        guard let line, !line.text.isEmpty else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        guard let content, let rubyLabel, labels.count == 3 else { return }
        // 발음을 글자 위에 얹을 때는 원문 줄을 루비 라벨이 대신 그린다.
        let texts = [line.ruby == nil ? line.text : "", line.pronunciation ?? "", line.translation ?? ""]

        let anchor = self.anchor ?? defaultAnchor
        /// 위에서부터 차례로 놓을 뷰와 그 크기.
        var rows: [(view: NSView, size: NSSize)] = []
        if let ruby = line.ruby {
            rubyLabel.segments = ruby
            rows.append((rubyLabel, rubyLabel.fittingSize(maxWidth: maxTextWidth(near: anchor))))
        }
        for (label, text) in zip(labels, texts) where !text.isEmpty {
            rows.append((label, textSize(of: text, with: label, near: anchor)))
        }
        var contentSize = NSSize.zero
        for row in rows {
            contentSize.width = max(contentSize.width, row.size.width)
            contentSize.height += row.size.height + (contentSize.height > 0 ? Self.lineGap : 0)
        }
        let size = NSSize(
            width: max(Self.minWidth, contentSize.width + Self.padding.width * 2),
            height: contentSize.height + Self.padding.height * 2
        )
        let target = Self.clamped(NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height))

        let wasVisible = panel.isVisible && !isHiding
        isHiding = false
        if wasVisible, shownLine == line { return }
        shownLine = line
        // 줄이 길어지면 치고 있는 자리까지 덮을 수 있다. 새 크기로 다시 따진다.
        isTypingHidden = overlapsTyping(target)
        panel.ignoresMouseEvents = isHoverHidden || isTypingHidden

        if wasVisible {
            // 글자는 겹쳐 바뀌고 패널은 그 길이에 맞춰 늘거나 준다.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            content.layer?.add(fade, forKey: "line")
        } else {
            panel.setFrame(target, display: false)
        }
        // 글자 크기는 미리 최종 크기로 잡고 가운데에 둔다. 패널이 움직이는 동안 줄바꿈이 바뀌지 않는다.
        let bounds = content.superview?.bounds ?? .zero
        content.frame = NSRect(
            x: bounds.midX - contentSize.width / 2, y: bounds.midY - contentSize.height / 2,
            width: contentSize.width, height: contentSize.height
        )
        rubyLabel.isHidden = line.ruby == nil
        for (label, text) in zip(labels, texts) {
            label.stringValue = text
            label.isHidden = text.isEmpty
        }
        var top = contentSize.height
        for row in rows {
            row.view.frame = NSRect(
                x: (contentSize.width - row.size.width) / 2, y: top - row.size.height,
                width: row.size.width, height: row.size.height
            )
            top -= row.size.height + Self.lineGap
        }

        if wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = visibleAlpha
            }
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // 마우스가 있는 자리에 나타났다면 처음부터 숨겨 둔다(가만히 있는 마우스는 들어왔다는 알림이 오지 않는다).
            if target.contains(NSEvent.mouseLocation) { beginHoverHiding() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = visibleAlpha
            }
        }
    }

    private func beginHoverHiding() {
        guard hidesOnHover, !isHoverHidden, !NSEvent.modifierFlags.contains(.command), let panel else { return }
        isHoverHidden = true
        applyHiding(duration: 0.15)
        // 클릭을 통과시키는 동안은 마우스가 나갔다는 알림도 오지 않는다. 숨겨 둔 동안만 위치를 직접 확인한다.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if !panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { self.endHoverHiding() }
            }
        }
    }

    private func endHoverHiding() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard isHoverHidden else { return }
        isHoverHidden = false
        applyHiding(duration: 0.2)
    }

    private func overlapsTyping(_ frame: NSRect) -> Bool {
        typingArea.map { frame.insetBy(dx: -8, dy: -8).intersects($0) } ?? false
    }

    /// 숨김 상태가 바뀐 것을 패널에 옮긴다. 숨긴 동안은 클릭이 아래 창으로 지나간다.
    private func applyHiding(duration: TimeInterval) {
        guard let panel else { return }
        panel.ignoresMouseEvents = isHoverHidden || isTypingHidden
        guard panel.isVisible, !isHiding else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            panel.animator().alphaValue = visibleAlpha
        }
    }

    private func hide() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // 사라지는 도중 다음 줄이 와서 다시 띄웠다면 닫지 않는다.
                guard let self, self.isHiding else { return }
                self.isHiding = false
                panel.orderOut(nil)
                self.endHoverHiding()
            }
        })
    }

    /// 글자가 차지할 크기. 한 줄에 다 들어가지 않으면 두 줄까지 쓰고, 그래도 넘치면 끝을 줄인다.
    /// 라벨이 글자 둘레에 두는 여백까지 맞아야 하므로 라벨 자신에게 잰다(따로 계산하면 조금 모자라 멀쩡한 줄이 잘린다).
    private func textSize(of text: String, with label: NSTextField, near anchor: NSPoint) -> NSSize {
        guard let cell = label.cell else { return .zero }
        let limit = NSRect(x: 0, y: 0, width: maxTextWidth(near: anchor), height: .greatestFiniteMagnitude)
        let shown = label.stringValue
        defer { label.stringValue = shown }
        label.stringValue = "A\nA"
        let twoLines = cell.cellSize(forBounds: limit).height
        label.stringValue = text
        let size = cell.cellSize(forBounds: limit)
        return NSSize(width: ceil(size.width), height: ceil(min(size.height, twoLines)))
    }

    private func maxTextWidth(near anchor: NSPoint) -> CGFloat {
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.frame.width ?? 1440
        return min(Self.maxTextWidth, screen * 0.75)
    }

    /// 패널이 기준점이 놓인 화면 밖으로 나가지 않게 한다.
    private static func clamped(_ frame: NSRect) -> NSRect {
        let point = NSPoint(x: frame.midX, y: frame.minY)
        guard let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.frame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, screen.minX + 8), max(screen.minX + 8, screen.maxX - frame.width - 8))
        frame.origin.y = min(max(frame.minY, screen.minY + 8), max(screen.minY + 8, screen.maxY - frame.height - 8))
        return frame
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let labels = [
            Self.makeLabel(font: Self.font, color: .labelColor),
            Self.makeLabel(font: Self.pronunciationFont, color: .secondaryLabelColor),
            Self.makeLabel(font: Self.translationFont, color: .secondaryLabelColor),
        ]
        let content = NSView()
        content.wantsLayer = true
        content.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        labels.forEach(content.addSubview)
        let rubyLabel = RubyLabel(font: Self.font)
        rubyLabel.isHidden = true
        content.addSubview(rubyLabel)

        let coverView = CoverBackgroundView(cornerRadius: Self.cornerRadius)
        let view = LyricsPanelView(content: content, cover: coverView, cornerRadius: Self.cornerRadius)
        view.onMoved = { [weak self, weak panel] in
            guard let frame = panel?.frame else { return }
            self?.anchor = NSPoint(x: frame.midX, y: frame.minY)
        }
        view.onMouseEntered = { [weak self] in self?.beginHoverHiding() }
        panel.contentView = view

        self.panel = panel
        self.content = content
        self.labels = labels
        self.rubyLabel = rubyLabel
        self.coverView = coverView
        panelView = view
        applyBackground()
        return panel
    }

    private func applyBackground() {
        guard let coverView, let panelView, let content else { return }
        let image = backgroundStyle == .cover ? artwork.flatMap(CoverBackgroundView.blurred) : nil
        // 대표 색은 색상만 가져오고 밝기는 정해 둔다. 어떤 커버에서도 흰 글자가 읽히게 어둡게 잡는다.
        let color = backgroundStyle == .color ? artwork.flatMap(AlbumColor.accent).map {
            AlbumColor.color(hue: $0.hue, saturation: min(max($0.saturation, 0.5), 0.85), lightness: 0.3)
        } : nil
        coverView.set(image: image, color: color)

        let isClear = backgroundStyle == .clear
        panelView.isBackgroundClear = isClear
        // 뒤의 화면이 비쳐서 글자가 묻힌다. 글자에 그림자를 둘러 어떤 화면 위에서도 읽히게 한다.
        // 커버가 알아볼 만큼 또렷하면 글자와 겹치는 부분이 생긴다. 그때도 그림자가 글자를 떼어 준다.
        content.shadow = isClear || image != nil ? Self.textShadow : nil

        // 커버나 그 색 위, 그리고 투명한 유리 위에서는 밝은/어두운 모드와 상관없이 흰 글자를 쓴다.
        let isWhite = image != nil || color != nil || isClear
        let text: NSColor = isWhite ? .white : .labelColor
        let secondary: NSColor = isWhite ? NSColor.white.withAlphaComponent(isClear ? 0.92 : 0.8) : .secondaryLabelColor
        for (index, label) in labels.enumerated() { label.textColor = index == 0 ? text : secondary }
        rubyLabel?.colors = (text, secondary)
    }

    private static let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    private static func makeLabel(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        return label
    }
}

/// 배경(유리/블러)을 깔고, 끌어서 패널을 옮기게 한다.
private final class LyricsPanelView: NSView {
    /// 끌어서 옮길 때마다. 끄는 도중에 줄이 바뀌어도 패널이 옛 자리로 돌아가지 않게 그때그때 알린다.
    var onMoved: (() -> Void)?

    var onMouseEntered: (() -> Void)?

    /// 끌기 시작한 순간의 마우스 위치(화면 좌표)와 패널 위치.
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    private let background: NSView

    /// 배경을 뒤가 비치는 유리로 바꾼다.
    /// 시스템의 투명한 유리(.clear)도 뒤를 완전히 흐려서 비치지 않는다. 유리 자체를 반쯤 비치게 해서 뒤의 화면이 보이게 한다.
    var isBackgroundClear = false {
        didSet {
            if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
                glass.style = isBackgroundClear ? .clear : .regular
            }
            background.alphaValue = isBackgroundClear ? 0.5 : 1
        }
    }

    init(content: NSView, cover: NSView, cornerRadius: CGFloat) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            background = effect
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        // 아래부터 배경, 커버(또는 그 색), 글자. 배경만 따로 감출 수 있게 글자를 배경 안에 넣지 않는다.
        for view in [background, cover] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        // 글자는 패널 가운데에 떠 있어야 하므로 패널 크기를 따라가는 뷰에 얹는다.
        let holder = NSView(frame: bounds)
        holder.autoresizingMask = [.width, .height]
        holder.addSubview(content)
        addSubview(holder)
    }

    required init?(coder: NSCoder) { fatalError() }

    // 마우스는 전부 여기서 받는다(글자나 배경이 가로채면 끌 수 없다).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        // 끄는 중에는 숨기지 않는다.
        if drag == nil { onMouseEntered?() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag = (NSEvent.mouseLocation, window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let drag else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
        onMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }
}

/// 살짝 흐린 앨범 커버와, 글자가 읽히도록 그 위에 덮는 어두운 막.
/// 커버는 고정 크기로 가운데에 놓는다. 줄마다 패널 크기가 바뀌어도 그림은 늘거나 줄지 않고, 보이는 범위만 달라진다.
private final class CoverBackgroundView: NSView {
    /// 커버를 그리는 한 변의 길이. 너무 크면 패널에 걸리는 부분이 한 가지 색으로만 보인다.
    /// 패널이 이보다 넓어지는 긴 줄에서만 그 너비에 맞춰 키운다.
    private static let side: CGFloat = 380
    private static let scrimOpacity: Float = 0.36

    private let imageLayer = CALayer()
    private let scrim = CALayer()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        scrim.backgroundColor = NSColor.black.cgColor
        scrim.opacity = Self.scrimOpacity
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(scrim)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 패널 크기가 바뀌는 애니메이션을 따라 미끄러지지 않게, 제자리에 바로 놓는다.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        scrim.frame = bounds
        CATransaction.commit()
        // 긴 줄에서 커버를 키울 때만은 패널과 같은 빠르기로 부드럽게 키운다.
        let side = max(Self.side, bounds.width)
        if imageLayer.bounds.width != side {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            imageLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            CATransaction.commit()
        }
    }

    /// 커버(또는 그 대표 색)를 바꾼다. 앞의 것과 겹쳐 바뀌고, 둘 다 nil이면 사라진다.
    /// 색은 조금 비치게 칠해서 아래의 유리 배경이 살아 있게 한다.
    func set(image: CGImage?, color: NSColor?) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.5
        layer?.add(fade, forKey: "cover")
        imageLayer.contents = image
        scrim.isHidden = image == nil
        layer?.backgroundColor = image == nil ? color?.withAlphaComponent(0.78).cgColor : nil
        isHidden = image == nil && color == nil
    }

    /// 커버를 조금만 흐리게 만든다. 무슨 커버인지는 알아볼 수 있고, 그 위의 글자를 방해할 만큼 또렷하지는 않게.
    static func blurred(_ image: NSImage) -> CGImage? {
        let side = 160
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = context.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        // 가장자리 바깥을 투명으로 보면 흐린 뒤 테두리가 어두워진다. 가장자리 색을 바깥으로 늘려 둔다.
        let blurred = CIImage(cgImage: small).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.5])
            // 흐리면 색이 탁해진다. 조금 진하게 되돌린다.
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
            .cropped(to: extent)
        return CIContext().createCGImage(blurred, from: extent)
    }
}
