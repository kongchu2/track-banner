import AppKit

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

    private var panel: NSPanel?
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
    /// 숨겨져 있지 않을 때의 불투명도.
    private var visibleAlpha: CGFloat { isHoverHidden ? 0 : 1 }

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
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }
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
        guard isHoverHidden, let panel else { return }
        isHoverHidden = false
        panel.ignoresMouseEvents = false
        guard panel.isVisible, !isHiding else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
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

        let view = LyricsPanelView(content: content, cornerRadius: Self.cornerRadius)
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
        return panel
    }

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

    init(content: NSView, cornerRadius: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        // 글자는 배경 안에서 가운데에 떠 있어야 하므로 배경 크기를 따라가는 뷰에 얹는다.
        let holder = NSView(frame: bounds)
        holder.autoresizingMask = [.width, .height]
        holder.addSubview(content)

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = holder
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
            holder.frame = effect.bounds
            effect.addSubview(holder)
            background = effect
        }
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
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
