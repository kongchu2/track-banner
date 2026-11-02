import AppKit
import SwiftUI

/// 시스템 알림처럼 생긴 플로팅 패널. 앱 아이콘 자리에 앨범 커버를 넣는다.
@MainActor
final class BannerController {
    private let size = NSSize(width: 344, height: 70)
    private let margin: CGFloat = 12
    /// 닫기 버튼이 배너 왼쪽 위 모서리 밖으로 걸치는 만큼 패널을 넓힌다.
    private let overhang: CGFloat = 7
    private let displayDuration: TimeInterval = 2.5

    private var panel: NSPanel?
    private var hosting: NSHostingView<BannerContent>?
    private var dismissTimer: Timer?
    private var isDismissing = false

    func show(track: Track, artwork: NSImage?) {
        let content = BannerContent(track: track, artwork: artwork)

        if let panel, let hosting, panel.isVisible, !isDismissing {
            // 이미 떠 있으면 내용만 바꾼다.
            hosting.rootView = content
        } else {
            present(content)
        }
        scheduleDismiss()
    }

    private func present(_ content: BannerContent) {
        let panel = self.panel ?? makePanel(content)
        hosting?.rootView = content
        isDismissing = false

        guard let screen = NSScreen.main?.visibleFrame else { return }
        // 배너 자체는 화면 모서리에서 margin만큼 떨어지고, 패널은 왼쪽·위로 overhang만큼 더 크다.
        let target = NSRect(
            x: screen.maxX - size.width - margin - overhang,
            y: screen.maxY - size.height - margin,
            width: size.width + overhang,
            height: size.height + overhang
        )

        // 화면 오른쪽 밖에서 미끄러져 들어온다.
        panel.setFrame(target.offsetBy(dx: target.width + margin, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        dismissTimer?.invalidate()
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // 사라지는 도중 새 곡이 와서 다시 띄웠다면 닫지 않는다.
                guard let self, self.isDismissing else { return }
                self.isDismissing = false
                panel.orderOut(nil)
            }
        })
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func makePanel(_ content: BannerContent) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width + overhang, height: size.height + overhang),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: content)
        let view = BannerView(bannerSize: size, overhang: overhang, content: hosting)
        view.onClick = { [weak self] in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            self?.dismiss()
        }
        view.onClose = { [weak self] in
            self?.dismiss()
        }
        view.onHover = { [weak self] hovering in
            // 마우스를 올려두면 사라지지 않는다.
            if hovering { self?.dismissTimer?.invalidate() } else { self?.scheduleDismiss() }
        }
        panel.contentView = view

        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// 배경(유리/블러) + 클릭·호버 처리.
/// 뷰는 배너보다 왼쪽·위로 overhang만큼 크고, 그 여백은 닫기 버튼이 걸치는 자리다.
private final class BannerView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let bannerRect: NSRect
    /// 시스템 알림처럼 마우스를 올렸을 때만 왼쪽 위 모서리에 나타나는 닫기 버튼.
    private let closeButton: CloseButton
    private var isCloseVisible = false

    init(bannerSize: NSSize, overhang: CGFloat, content: NSView) {
        bannerRect = NSRect(x: overhang, y: 0, width: bannerSize.width, height: bannerSize.height)

        // 버튼 중심을 배너의 둥근 모서리 위에 둔다.
        let buttonSize = CloseButton.diameter
        let center = NSPoint(x: bannerRect.minX + 4, y: bannerRect.maxY - 4)
        closeButton = CloseButton(frame: NSRect(
            x: center.x - buttonSize / 2,
            y: center.y - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        ))

        super.init(frame: NSRect(
            x: 0, y: 0,
            width: bannerSize.width + overhang,
            height: bannerSize.height + overhang
        ))

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = content
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            content.frame = effect.bounds
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            background = effect
        }
        background.frame = bannerRect
        addSubview(background)

        closeButton.alphaValue = 0
        closeButton.onClick = { [weak self] in
            self?.setCloseVisible(false, animated: false)
            self?.onClose?()
        }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setCloseVisible(_ visible: Bool, animated: Bool) {
        isCloseVisible = visible
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                closeButton.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            closeButton.alphaValue = visible ? 1 : 0
        }
    }

    // 클릭이 SwiftUI 뷰로 새지 않도록 배너 영역은 전부 여기서 받는다.
    // 닫기 버튼만 예외로 버튼 자신이 받고, 그 밖의 여백은 통과시킨다.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if isCloseVisible, closeButton.frame.contains(local) { return closeButton }
        return bannerRect.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        setCloseVisible(false, animated: false)
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bannerRect.union(closeButton.frame),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        setCloseVisible(true, animated: true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setCloseVisible(false, animated: true)
        onHover?(false)
    }
}

/// macOS 알림의 닫기 버튼처럼 생긴 작은 원형 버튼: 반투명 재질 + 얇은 테두리 + 회색 X.
private final class CloseButton: NSView {
    static let diameter: CGFloat = 20

    var onClick: (() -> Void)?

    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("닫기")

        let radius = frame.width / 2
        icon.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = icon
            glass.frame = bounds
            addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            addSubview(effect)
            addSubview(icon)

            wantsLayer = true
            layer?.cornerRadius = radius
            layer?.borderWidth = 0.5
            updateBorderColor()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        guard let layer, layer.borderWidth > 0 else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 누르는 동안 X를 진하게.
    override func mouseDown(with event: NSEvent) {
        icon.contentTintColor = .labelColor
    }

    override func mouseUp(with event: NSEvent) {
        icon.contentTintColor = .secondaryLabelColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

struct BannerContent: View {
    let track: Track
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            cover
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(track.artist)
                    .font(.system(size: 13))
                Text(track.album)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.25)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
