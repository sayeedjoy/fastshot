import AppKit

/// Brief, non-activating confirmation shown after the overlay closes, in the spirit of the system volume HUD.
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0
    static func show(_ text: String, symbol: String) {
        generation += 1; let current = generation
        panel?.orderOut(nil)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold); icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .labelColor; label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, label]); stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 11, right: 18)
        let fitting = stack.fittingSize
        let size = CGSize(width: min(520, ceil(fitting.width)), height: ceil(fitting.height))
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.maskImage = roundedMask(size: size, radius: size.height / 2)
        stack.frame = effect.bounds; stack.autoresizingMask = [.width, .height]; effect.addSubview(stack)

        let window = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = effect
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame { window.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.12)) }
        window.alphaValue = 0; window.orderFrontRegardless(); panel = window
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; window.animator().alphaValue = 1 }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard current == generation else { return }
            await NSAnimationContext.runAnimationGroup { context in context.duration = 0.3; window.animator().alphaValue = 0 }
            if current == generation { window.orderOut(nil); panel = nil }
        }
    }
    private static func roundedMask(size: CGSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius); image.resizingMode = .stretch
        return image
    }
}
