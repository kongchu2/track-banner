import AppKit
import ApplicationServices

/// 다른 앱에서 글자를 치고 있는 자리를 알려 준다. 손쉬운 사용 권한이 있어야 하고, 없으면 아무것도 알리지 않는다.
@MainActor
final class TypingWatcher {
    /// 마지막으로 글자를 친 뒤 이만큼 지나면 더는 치고 있지 않다고 본다.
    private static let idleDelay: TimeInterval = 2
    /// 키를 누른 뒤 그 앱이 커서를 옮길 때까지 기다리는 시간.
    private static let caretDelay: TimeInterval = 0.05
    /// 응답 없는 앱에 물었을 때 기다리는 시간.
    nonisolated private static let messagingTimeout: Float = 0.25

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 손쉬운 사용 권한을 켜 달라는 시스템 안내를 띄운다.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 글자를 치고 있는 자리(화면 좌표). 치기를 멈췄거나 자리를 알 수 없으면 nil.
    var onArea: ((NSRect?) -> Void)?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private var monitor: Any?
    private var trustTimer: Timer?
    private var idleTimer: Timer?
    private var isQuerying = false
    private let queue = DispatchQueue(label: "com.kongchu2.trackbanner.typing", qos: .userInitiated)

    private func start() {
        guard !installMonitor() else { return }
        // 권한은 나중에 시스템 설정에서 켜진다. 켜질 때까지 가끔 확인한다.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.installMonitor() else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
            }
        }
    }

    private func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onArea?(nil)
    }

    private func installMonitor() -> Bool {
        guard Self.isTrusted else { return false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keyPressed(event) }
        }
        return monitor != nil
    }

    private func keyPressed(_ event: NSEvent) {
        // 단축키는 글자를 치는 것이 아니다.
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.idleTimer = nil
                self?.onArea?(nil)
            }
        }
        // 앞의 물음이 아직 끝나지 않았으면 그 답을 쓴다. 느린 앱에 물음이 쌓이지 않는다.
        guard !isQuerying else { return }
        isQuerying = true
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 손쉬운 사용의 좌표는 주 모니터의 왼쪽 위가 원점이고 아래로 자란다.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // 다른 앱의 대답을 기다려야 하므로 메인 스레드 밖에서 묻는다.
        queue.asyncAfter(deadline: .now() + Self.caretDelay) { [weak self] in
            let area = Self.typingArea(frontmost: frontmost).map {
                NSRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height).insetBy(dx: -1, dy: -1)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isQuerying = false
                    // 묻는 사이에 껐거나 치기를 멈췄으면 버린다.
                    guard self.isEnabled, self.idleTimer != nil else { return }
                    self.onArea?(area)
                }
            }
        }
    }

    // MARK: - 손쉬운 사용

    /// 글자를 치고 있는 자리(손쉬운 사용 좌표). 커서 위치를 알려 주는 앱이면 커서, 아니면 입력란, 그것도 모르면 맨 앞 창.
    nonisolated private static func typingArea(frontmost: pid_t?) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        // 시스템 전체 요소에 걸면 이 프로세스의 모든 물음에 적용된다.
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        if let focused = element(of: system, kAXFocusedUIElementAttribute) {
            if let area = caretRect(in: focused) ?? frame(of: focused) { return area }
        }
        guard let frontmost else { return nil }
        return element(of: AXUIElementCreateApplication(frontmost), kAXFocusedWindowAttribute).flatMap(frame)
    }

    nonisolated private static func caretRect(in element: AXUIElement) -> CGRect? {
        guard let selection = value(of: element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection, .cfRange, &range) else { return nil }
        // 길이가 0인 범위의 자리를 알려 주지 않는 앱이 있다. 그때는 커서 바로 앞 글자의 자리를 쓴다.
        for var candidate in [range, CFRange(location: max(0, range.location - 1), length: 1)] {
            guard let parameter = AXValueCreate(.cfRange, &candidate) else { continue }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
            ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            // 자리를 모르는 앱은 빈 사각형이나 화면 구석을 돌려준다.
            if AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero { return rect }
        }
        return nil
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(of: element, kAXPositionAttribute), let size = value(of: element, kAXSizeAttribute) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(position, .cgPoint, &rect.origin), AXValueGetValue(size, .cgSize, &rect.size),
              !rect.isEmpty
        else { return nil }
        return rect
    }

    nonisolated private static func attribute(of element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    nonisolated private static func element(of element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = attribute(of: element, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    nonisolated private static func value(of element: AXUIElement, _ name: String) -> AXValue? {
        guard let result = attribute(of: element, name), CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        return (result as! AXValue)
    }
}
