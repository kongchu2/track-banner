import AppKit
import SwiftUI

/// 시스템 알림처럼 생긴 플로팅 패널. 앱 아이콘 자리에 앨범 커버를 넣는다.
@MainActor
final class BannerController {
    private let size = NSSize(width: 344, height: 70)
    private let margin: CGFloat = 12
    private let displayDuration: TimeInterval = 5

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
        let target = NSRect(
            x: screen.maxX - size.width - margin,
            y: screen.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )

        // 화면 오른쪽 밖에서 미끄러져 들어온다.
        panel.setFrame(target.offsetBy(dx: size.width + margin, dy: 0), display: false)
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
            contentRect: NSRect(origin: .zero, size: size),
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
        let view = BannerView(frame: NSRect(origin: .zero, size: size), content: hosting)
        view.onClick = { [weak self] in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
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
private final class BannerView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    init(frame: NSRect, content: NSView) {
        super.init(frame: frame)

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
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
    }

    required init?(coder: NSCoder) { fatalError() }

    // 클릭이 SwiftUI 뷰로 새지 않도록 전부 여기서 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
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
