import AppKit

/// A finished screenshot kept on top of other apps for reference. It never activates FastShot,
/// so the app underneath keeps focus while the pin is moved, zoomed or copied.
final class PinnedImageWindow: NSPanel {
    let image: CGImage
    /// Point size at which one image pixel covers one display pixel.
    let actualSize: CGSize
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onClose: (() -> Void)?
    var zoom: CGFloat { frame.width / max(1, actualSize.width) }

    init(image: CGImage, frame: CGRect, actualSize: CGSize) {
        self.image = image; self.actualSize = actualSize
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isFloatingPanel = true; hidesOnDeactivate = false; level = .floating
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinnedImageView(frame: CGRect(origin: .zero, size: frame.size), window: self)
        setAccessibilityLabel("Pinned screenshot, \(image.width) × \(image.height) pixels")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setZoom(_ zoom: CGFloat, around anchor: CGPoint? = nil) {
        let next = PinLayout.zoomed(frame, to: zoom, actualSize: actualSize, anchor: anchor ?? CGPoint(x: frame.midX, y: frame.midY))
        setFrame(next, display: true)
        (contentView as? PinnedImageView)?.flash("\(Int((self.zoom * 100).rounded()))%")
    }
    func setOpacity(_ value: CGFloat) {
        alphaValue = min(1, max(0.2, value))
        (contentView as? PinnedImageView)?.flash("Opacity \(Int((alphaValue * 100).rounded()))%")
    }
    override func close() { onClose?(); onClose = nil; super.close() }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, key) {
        case (53, _): close()
        case (_, "w") where command: close()
        case (_, "c") where command: onCopy?()
        case (_, "s") where command: onSave?()
        case (_, "e") where command: onEdit?()
        case (_, "0") where command: setZoom(1)
        case (_, "=") where command, (_, "+") where command: setZoom(zoom * 1.25)
        case (_, "-") where command: setZoom(zoom / 1.25)
        case (123, _), (124, _), (125, _), (126, _):
            // Arrow keys nudge by a point, or ten with Shift, for precise alignment.
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
            setFrameOrigin(CGPoint(x: frame.minX + dx, y: frame.minY + dy))
        default: super.keyDown(with: event)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), ["w", "c", "s", "e", "0", "=", "+", "-"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event); return true
    }
}

private final class PinnedImageView: NSView {
    private unowned let pin: PinnedImageWindow
    private let closeButton = NSButton()
    private let badge = NSTextField(labelWithString: "")
    private var badgeTask: Task<Void, Never>?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, window: PinnedImageWindow) {
        pin = window
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pin")
        closeButton.symbolConfiguration = .init(pointSize: 16, weight: .semibold).applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.65)]))
        closeButton.isBordered = false; closeButton.bezelStyle = .inline; closeButton.imageScaling = .scaleNone
        closeButton.target = self; closeButton.action = #selector(closePin); closeButton.isHidden = true
        closeButton.setAccessibilityLabel("Close pin")
        addSubview(closeButton)
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold); badge.textColor = .white; badge.alignment = .center
        badge.wantsLayer = true; badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor; badge.layer?.cornerRadius = 5
        badge.isHidden = true
        addSubview(badge)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Pinned screenshot. Drag to move, scroll to zoom, double-click or Escape to close, Control-click for options.")
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Renderer.drawImage(pin.image, in: bounds)
        // A hairline edge separates the pin from screen content that looks the same.
        NSColor.black.withAlphaComponent(0.28).setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); edge.lineWidth = 1; edge.stroke()
    }
    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: 4, y: 4, width: 22, height: 22)
        let width = ceil(badge.intrinsicContentSize.width) + 14
        badge.frame = CGRect(x: (bounds.width - width) / 2, y: max(4, bounds.height - 26), width: width, height: 20)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = bounds.width < 60 || bounds.height < 40 }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    func flash(_ text: String) {
        badge.stringValue = text; badge.isHidden = false; needsLayout = true
        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self?.badge.isHidden = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { pin.close(); return }
        pin.performDrag(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // Option-scroll fades the pin; plain scroll zooms around the pointer.
        if event.modifierFlags.contains(.option) {
            pin.setOpacity(pin.alphaValue + (delta > 0 ? 0.05 : -0.05))
        } else {
            let factor = event.hasPreciseScrollingDeltas ? 1 + delta * 0.01 : pow(1.1, delta)
            pin.setZoom(pin.zoom * max(0.5, min(2, factor)), around: NSEvent.mouseLocation)
        }
    }
    override func magnify(with event: NSEvent) { pin.setZoom(pin.zoom * (1 + event.magnification), around: NSEvent.mouseLocation) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String?, key: String = "", _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        item("Copy", "doc.on.doc", key: "c", #selector(copyPin))
        item("Quick Save", "bolt.fill", key: "s", #selector(savePin))
        item("Edit…", "pencil.and.outline", key: "e", #selector(editPin))
        menu.addItem(.separator())
        item("Actual Size", nil, key: "0", #selector(actualSize))
        item("Zoom In", "plus.magnifyingglass", key: "=", #selector(zoomIn))
        item("Zoom Out", "minus.magnifyingglass", key: "-", #selector(zoomOut))
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: ""); opacity.submenu = NSMenu()
        for value in [100, 80, 60, 40] {
            let level = NSMenuItem(title: "\(value)%", action: #selector(changeOpacity(_:)), keyEquivalent: "")
            level.target = self; level.tag = value; level.state = Int((pin.alphaValue * 100).rounded()) == value ? .on : .off
            opacity.submenu?.addItem(level)
        }
        menu.addItem(opacity)
        menu.addItem(.separator())
        item("Close", "xmark", key: "w", #selector(closePin))
        item("Close All Pins", nil, #selector(closeAll))
        return menu
    }
    @objc private func copyPin() { pin.onCopy?() }
    @objc private func savePin() { pin.onSave?() }
    @objc private func editPin() { pin.onEdit?() }
    @objc private func actualSize() { pin.setZoom(1) }
    @objc private func zoomIn() { pin.setZoom(pin.zoom * 1.25) }
    @objc private func zoomOut() { pin.setZoom(pin.zoom / 1.25) }
    @objc private func changeOpacity(_ sender: NSMenuItem) { pin.setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func closePin() { pin.close() }
    @objc private func closeAll() { pin.onCloseAll?() }
}

nonisolated enum PinLayout {
    /// Point size that shows every image pixel on one display pixel.
    static func actualSize(pixelSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: pixelSize.width / max(1, scale), height: pixelSize.height / max(1, scale))
    }
    /// A pin opens over the area it was captured from; otherwise centred at actual size, fitted to 80% of the screen.
    static func frame(actualSize: CGSize, visible: CGRect, over anchor: CGRect? = nil) -> CGRect {
        if let anchor, anchor.width >= 1, anchor.height >= 1 { return anchor }
        let fit = min(1, visible.width * 0.8 / max(1, actualSize.width), visible.height * 0.8 / max(1, actualSize.height))
        let size = CGSize(width: max(1, (actualSize.width * fit).rounded()), height: max(1, (actualSize.height * fit).rounded()))
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
    /// Resize around a fixed screen point, keeping the aspect ratio, between a 24 pt short side and 8× actual size.
    static func zoomed(_ frame: CGRect, to zoom: CGFloat, actualSize: CGSize, anchor: CGPoint) -> CGRect {
        let shortest = max(1, min(actualSize.width, actualSize.height))
        let zoom = min(8, max(zoom, 24 / shortest))
        let size = CGSize(width: actualSize.width * zoom, height: actualSize.height * zoom)
        let fx = frame.width > 0 ? (anchor.x - frame.minX) / frame.width : 0.5
        let fy = frame.height > 0 ? (anchor.y - frame.minY) / frame.height : 0.5
        return CGRect(x: anchor.x - fx * size.width, y: anchor.y - fy * size.height, width: size.width, height: size.height)
    }
}
