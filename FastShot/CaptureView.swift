import AppKit

final class CaptureWindow: NSWindow, NSWindowDelegate {
    var captureView: CaptureView? {
        (contentView as? CaptureView) ?? (contentView as? CaptureEditorView)?.canvas ?? contentView?.subviews.last as? CaptureView
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        captureView?.coordinator.cancel()
        return false
    }
    init(screen: NSScreen, source: CGImage, coordinator: CaptureCoordinator) {
        let available = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        super.init(contentRect: available, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "FastShot Editor"
        minSize = CGSize(width: 920, height: 400)
        delegate = self
        let editor = CaptureEditorView(frame: CGRect(origin: .zero, size: available.size), source: source, coordinator: coordinator, backingScale: screen.backingScaleFactor)
        contentView = editor
        makeFirstResponder(editor.canvas)
        setAccessibilityLabel("FastShot screenshot editor")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    init(screen: NSScreen, source: CGImage, regions: [WindowRegion], mode: CaptureMode, coordinator: CaptureCoordinator) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false; level = .screenSaver; backgroundColor = .clear; isOpaque = false; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let frame = CGRect(origin: .zero, size: screen.frame.size)
        let container = NSView(frame: frame); container.wantsLayer = true
        let backdrop = CaptureBackdrop(frame: frame, source: source)
        let view = CaptureView(frame: frame, source: source, regions: regions, mode: mode, coordinator: coordinator)
        for subview in [backdrop, view] { subview.autoresizingMask = [.width, .height]; container.addSubview(subview) }
        view.backdrop = backdrop
        contentView = container; makeFirstResponder(view)
        setAccessibilityLabel("FastShot capture overlay")
    }
}

/// The frozen screen, drawn once, under GPU-composited dimming and selection outline,
/// so following the pointer never redraws full-screen pixels.
final class CaptureBackdrop: NSView {
    private let source: CGImage
    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    init(frame: CGRect, source: CGImage) {
        self.source = source
        super.init(frame: frame)
        wantsLayer = true
        dim.fillRule = .evenOdd; dim.fillColor = NSColor.black.withAlphaComponent(0.48).cgColor
        outline.fillColor = nil; outline.lineWidth = 1.5
        for shape in [dim, outline] {
            shape.frame = bounds
            shape.actions = ["path": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(shape)
        }
        highlight(nil)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) { Renderer.drawImage(source, in: bounds) }
    override func layout() { super.layout(); dim.frame = bounds; outline.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// `rect` is in the flipped coordinates of the capture view; this view and its layers are not flipped.
    func highlight(_ rect: CGRect?) {
        let hole = rect.map { CGRect(x: $0.minX, y: bounds.height - $0.maxY, width: $0.width, height: $0.height) }
        let path = CGMutablePath(); path.addRect(bounds)
        if let hole { path.addRect(hole) }
        dim.path = path
        outline.path = hole.map { CGPath(rect: $0, transform: nil) }
        outline.strokeColor = NSColor.controlAccentColor.cgColor
    }
}

/// Zoomed pixels and colour under the pointer; a small layer of its own, moved rather than redrawn with the overlay.
final class MagnifierView: NSView {
    private let source: CGImage
    private lazy var sourceBitmap = NSBitmapImageRep(cgImage: source)
    var pixel: CGPoint = .zero { didSet { if pixel != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    init(source: CGImage) {
        self.source = source
        super.init(frame: CGRect(x: 0, y: 0, width: 130, height: 132))
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let sample = CGRect(x: max(0, min(CGFloat(source.width) - 20, pixel.x - 10)), y: max(0, min(CGFloat(source.height) - 20, pixel.y - 10)), width: 20, height: 20)
        guard let zoom = source.cropping(to: sample) else { return }
        let rect = CGRect(x: 0.5, y: 0.5, width: 110, height: 110)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.imageInterpolation = .none
        Renderer.drawImage(zoom, in: rect); NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke(); NSBezierPath(rect: rect).stroke()
        let cross = NSBezierPath(); cross.move(to: CGPoint(x: rect.midX - 8, y: rect.midY)); cross.line(to: CGPoint(x: rect.midX + 8, y: rect.midY)); cross.move(to: CGPoint(x: rect.midX, y: rect.midY - 8)); cross.line(to: CGPoint(x: rect.midX, y: rect.midY + 8)); cross.stroke()
        let hex = sourceBitmap.colorAt(x: max(0, min(source.width - 1, Int(pixel.x))), y: max(0, min(source.height - 1, Int(pixel.y))))?.hex ?? ""
        ("\(Int(pixel.x)), \(Int(pixel.y)) \(hex)" as NSString).draw(at: CGPoint(x: rect.minX, y: rect.maxY + 4), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black])
    }
}

/// Feedback text over the capture area that never takes the pointer's clicks.
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CaptureView: NSView, NSTextFieldDelegate {
    let source: CGImage
    var onEditorHover: ((ToolButton, Bool) -> Void)?
    let isEditor: Bool
    let regions: [WindowRegion]
    unowned let coordinator: CaptureCoordinator
    let history = EditHistory()
    var selection: CGRect? { didSet { updateControls() } }
    var mode: CaptureMode
    var tool: Tool = .select
    var selectedID: UUID?
    private var start: CGPoint = .zero
    private var pointer: CGPoint = .zero
    private var draft: Annotation?
    private var moving: Annotation?
    private var originalSelection: CGRect?
    private var resizeHandle: Int?
    private var hoverLabel = NSTextField(labelWithString: "")
    private var selecting = false
    private var hoveredWindow: CGRect?
    private var preview: CGImage?
    /// Set by the overlay window; when present it paints the screen and dimming, and this view stays transparent.
    weak var backdrop: CaptureBackdrop?
    private let sizeLabel = PassthroughLabel(labelWithString: "")
    private lazy var magnifier = MagnifierView(source: source)
    private var modeBar = NSStackView()
    private var toolBar = NSStackView()
    private var actionBar = NSStackView()
    /// Related tools share one button; the button shows the variant last used in its group.
    private static let toolGroups: [(title: String, tools: [Tool])] = [
        ("Select", [.select]), ("Draw", [.pen, .highlight]), ("Lines", [.line, .arrow]), ("Shapes", [.rect, .ellipse]),
        ("Text", [.text]), ("Step", [.step]), ("Redact", [.redact]), ("Blur & mosaic", [.blur, .pixelate]),
    ]
    private var groupButtons: [ToolButton] = []
    private lazy var groupVariant = Self.toolGroups.map { $0.tools[0] }
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var styleButton: NSButton!
    /// The vertical tool bar's pin; the editor already shows one with its actions.
    private var toolPinViews: [NSView] = []
    private lazy var stylePopover = makeStylePopover()
    private let colorWell = NSColorWell()
    private var styleSliders: [NSSlider] = []
    private var status = NSTextField(labelWithString: "")
    private var textField: NSTextField?
    private var textPoint = CGPoint.zero
    private var editingText: Annotation?
    private var color: String
    private var stroke: CGFloat
    private var fontSize: CGFloat
    private var strength: CGFloat = 12
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The click that lands on a not-yet-key overlay starts the drag instead of only focusing the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The selection in screen coordinates, so a pin can open exactly over the captured area.
    var selectionOnScreen: CGRect? {
        guard let selection, let window else { return nil }
        return window.convertToScreen(convert(selection, to: nil))
    }
    var pixelCrop: CGRect? {
        selection.map { Geometry.pixelCrop($0, viewSize: bounds.size, imageSize: CGSize(width: source.width, height: source.height)) }
    }
    private var scaleX: CGFloat { CGFloat(source.width) / bounds.width }
    private var scaleY: CGFloat { CGFloat(source.height) / bounds.height }

    init(frame: CGRect, source: CGImage, regions: [WindowRegion], mode: CaptureMode, coordinator: CaptureCoordinator, isEditor: Bool = false) {
        self.isEditor = isEditor
        self.source = source; self.regions = regions; self.mode = mode; self.coordinator = coordinator
        color = coordinator.preferences.value.annotationColor; stroke = coordinator.preferences.value.strokeWidth; fontSize = coordinator.preferences.value.fontSize
        super.init(frame: frame)
        setupControls()
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(isEditor ? "Screenshot annotation canvas. Escape closes the editor." : "Capture area. Drag to select. Escape cancels. Keys 1, 2, 3 change capture mode.")
    }
    func editorControls() -> (actions: NSStackView, tools: NSStackView) {
        modeBar.isHidden = true
        toolBar.orientation = .horizontal
        for view in toolPinViews { view.removeFromSuperview() }
        for bar in [actionBar, toolBar] {
            bar.removeFromSuperview()
            bar.layer?.shadowOpacity = 0
            bar.layer?.borderWidth = 0
        }
        return (actionBar, toolBar)
    }
    func resizeEditorCanvas(to size: CGSize) {
        guard isEditor, frame.size != size else { return }
        commitText()
        setFrameSize(size)
        selection = bounds
        refreshPreview()
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select && selection != nil ? .arrow : .crosshair)
        guard !isEditor, tool == .select, let selection, history.items.isEmpty else { return }
        let grip: CGFloat = 6
        addCursorRect(CGRect(x: selection.minX + grip, y: selection.minY - grip, width: max(0, selection.width - grip * 2), height: grip * 2), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: selection.minX + grip, y: selection.maxY - grip, width: max(0, selection.width - grip * 2), height: grip * 2), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: selection.minX - grip, y: selection.minY + grip, width: grip * 2, height: max(0, selection.height - grip * 2)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: selection.maxX - grip, y: selection.minY + grip, width: grip * 2, height: max(0, selection.height - grip * 2)), cursor: .resizeLeftRight)
        for p in corners(selection) { addCursorRect(CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16), cursor: .crosshair) }
    }
    private func button(_ label: String, symbol: String, action: Selector) -> NSButton {
        let b = ToolButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        b.bezelStyle = .inline; b.isBordered = false; b.toolTip = label; b.setAccessibilityLabel(label)
        b.symbolConfiguration = .init(pointSize: 16, weight: .medium); b.imageScaling = .scaleNone
        b.contentTintColor = .black
        (b.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        b.usesBlackGlyphs = true
        b.wantsLayer = true; b.layer?.cornerRadius = 7; b.layer?.cornerCurve = .continuous
        b.hint = label; b.toolTip = nil; b.onHover = { [weak self] button, inside in self?.showHint(for: button, inside) }
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true; b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return b
    }
    private func panel(_ stack: NSStackView, vertical: Bool = false) {
        stack.orientation = vertical ? .vertical : .horizontal; stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.wantsLayer = true; stack.layer?.cornerRadius = 12; stack.layer?.cornerCurve = .continuous; stack.layer?.borderWidth = 0.5
        stack.layer?.shadowOpacity = 0.3; stack.layer?.shadowRadius = 10; stack.layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(stack)
    }
    private func setupControls() {
        sizeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium); sizeLabel.textColor = .white
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.8); sizeLabel.drawsBackground = true; sizeLabel.isHidden = true
        magnifier.isHidden = true
        addSubview(sizeLabel); addSubview(magnifier)
        modeBar.identifier = NSUserInterfaceItemIdentifier("capture-mode-panel")
        panel(modeBar)
        for (index, mode) in CaptureMode.allCases.enumerated() {
            let b = NSButton(title: "\(mode.title)  \(index + 1)", target: self, action: #selector(changeMode(_:)))
            b.tag = index; b.bezelStyle = .recessed; b.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading
            modeBar.addArrangedSubview(b)
        }
        panel(toolBar, vertical: true)
        for (index, group) in Self.toolGroups.enumerated() {
            let b = button(group.title, symbol: group.tools[0].symbol, action: #selector(changeTool(_:))) as! ToolButton
            b.tag = index; b.hasVariants = group.tools.count > 1
            if b.hasVariants { b.menu = variantMenu(for: index) }
            toolBar.addArrangedSubview(b); groupButtons.append(b)
        }
        undoButton = button("Undo (⌘Z)", symbol: "arrow.uturn.backward", action: #selector(undoEdit))
        redoButton = button("Redo (⌘⇧Z)", symbol: "arrow.uturn.forward", action: #selector(redoEdit))
        (undoButton as? ToolButton)?.dimsWhenUnavailable = true
        (redoButton as? ToolButton)?.dimsWhenUnavailable = true
        toolBar.addArrangedSubview(undoButton); toolBar.addArrangedSubview(redoButton)
        // One compact swatch button; colour and sizes open in a popover anchored to it.
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 26).isActive = true
        toolBar.addArrangedSubview(divider)
        styleButton = button("Colour & size", symbol: "circle.fill", action: #selector(showStyle(_:)))
        toolBar.addArrangedSubview(styleButton)
        let pinDivider = NSBox(); pinDivider.boxType = .separator
        pinDivider.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let toolPin = button("Pin to screen (⌘P)", symbol: "pin", action: #selector(output(_:)))
        toolPin.tag = 4
        toolPinViews = [pinDivider, toolPin]
        toolPinViews.forEach(toolBar.addArrangedSubview)
        panel(actionBar)
        for (label, symbol, action) in [("Quick save (⌘⇧S)", "bolt.fill", OutputAction.quickSave), ("Copy text (⌘⇧C). Hold Option for full language support (slower).", "text.viewfinder", .ocr), ("Pin to screen (⌘P)", "pin", .pin), ("Save as… (⌘S)", "square.and.arrow.down", .save), ("Copy (⌘C)", "doc.on.doc", .copy)] {
            let b = button(label, symbol: symbol, action: #selector(output(_:)))
            b.tag = switch action { case .quickSave: 0; case .ocr: 1; case .save: 2; case .copy: 3; case .pin: 4 }
            actionBar.addArrangedSubview(b)
        }
        actionBar.addArrangedSubview(button("Cancel (Esc)", symbol: "xmark", action: #selector(cancelCapture)))
        hoverLabel.font = .systemFont(ofSize: 12, weight: .medium); hoverLabel.textColor = .white; hoverLabel.alignment = .center
        hoverLabel.drawsBackground = false; hoverLabel.wantsLayer = true; hoverLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        hoverLabel.layer?.cornerRadius = 6; hoverLabel.isHidden = true; addSubview(hoverLabel)
        status.textColor = .white; status.backgroundColor = NSColor.black.withAlphaComponent(0.8); status.drawsBackground = true
        status.font = .monospacedSystemFont(ofSize: 12, weight: .medium); status.isHidden = true; addSubview(status)
        updateControls()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateControls() }
    private func updateControls() {
        let editing = selection != nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            modeBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            for stack in [toolBar, actionBar] { stack.layer?.backgroundColor = NSColor.white.cgColor }
            for stack in [modeBar, toolBar, actionBar] { stack.layer?.borderColor = NSColor.separatorColor.cgColor }
        }
        if !editing { hoverLabel.isHidden = true }
        modeBar.isHidden = editing || !coordinator.preferences.value.showCaptureModePanel; toolBar.isHidden = !editing; actionBar.isHidden = !editing
        // The active tool is a light grey tile behind its black glyph (drawn by ToolButton).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, button) in groupButtons.enumerated() {
                let variant = groupVariant[index], active = variant == tool
                button.hint = "\(variant.title)  \(variant.key.uppercased())" + (button.hasVariants ? "  ·  click again for more" : "")
                button.image = NSImage(systemSymbolName: variant.symbol, accessibilityDescription: variant.title)
                button.setAccessibilityLabel(Self.toolGroups[index].title + ": " + variant.title)
                button.contentTintColor = .black
                button.state = active ? .on : .off; button.setAccessibilityValue(active ? "selected" : nil)
            }
        }
        styleButton?.contentTintColor = .black
        undoButton?.isEnabled = history.canUndo; redoButton?.isEnabled = history.canRedo
        for (index, view) in modeBar.arrangedSubviews.enumerated() { (view as? NSButton)?.state = CaptureMode.allCases[index] == mode ? .on : .off }
        updatePointerFeedback()
        needsLayout = true; needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
    private var activeRect: CGRect? { selection ?? (selecting ? Geometry.rect(start, pointer) : hoveredWindow) }
    /// Dimming, the size label and the magnifier are layers of their own; moving them redraws none of the frozen screen.
    private func updatePointerFeedback() {
        let active = activeRect
        backdrop?.highlight(active)
        if let active, !isEditor {
            let dimensions = Geometry.pixelCrop(active, viewSize: bounds.size, imageSize: CGSize(width: source.width, height: source.height))
            sizeLabel.stringValue = " \(Int(dimensions.width)) × \(Int(dimensions.height)) "
            sizeLabel.frame = CGRect(origin: CGPoint(x: active.minX, y: max(4, active.minY - 23)), size: sizeLabel.fittingSize)
            sizeLabel.isHidden = false
        } else { sizeLabel.isHidden = true }
        magnifier.isHidden = isEditor || selection != nil || !coordinator.preferences.value.showMagnifier
        if !magnifier.isHidden {
            magnifier.setFrameOrigin(CGPoint(x: min(bounds.width - 130, pointer.x + 22), y: min(bounds.height - 150, pointer.y + 22)))
            magnifier.pixel = CGPoint(x: pointer.x * scaleX, y: pointer.y * scaleY)
        }
    }
    /// Pointer feedback before a selection exists; without a backdrop this view paints the dimming itself.
    private func pointerChanged() {
        updatePointerFeedback()
        if backdrop == nil { needsDisplay = true }
    }
    override func layout() {
        super.layout()
        if isEditor {
            status.frame = CGRect(x: 10, y: max(0, bounds.height - 36), width: max(0, bounds.width - 20), height: 24)
            return
        }
        modeBar.frame = CGRect(x: (bounds.width - 340) / 2, y: 20, width: 340, height: 40)
        guard let selection else { return }
        let toolHeight = min(ceil(toolBar.fittingSize.height), bounds.height - 16)
        let right = selection.maxX + 10
        toolBar.frame = CGRect(x: right + 46 <= bounds.width ? right : max(8, selection.minX - 56), y: max(8, min(selection.minY, bounds.height - toolHeight - 8)), width: 46, height: toolHeight)
        let barWidth = ceil(actionBar.fittingSize.width)
        actionBar.frame = CGRect(x: max(8, min(selection.maxX - barWidth, bounds.width - barWidth - 8)), y: min(bounds.height - 52, selection.maxY + 10), width: barWidth, height: 44)
        status.frame = CGRect(x: max(10, (bounds.width - min(780, bounds.width - 40)) / 2), y: bounds.height - 44, width: min(780, bounds.width - 40), height: 24)
    }
    private func pixelPoint(_ p: CGPoint) -> CGPoint {
        guard let crop = pixelCrop else { return .zero }
        return CGPoint(x: p.x * scaleX - crop.minX, y: p.y * scaleY - crop.minY)
    }
    private func clamped(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height)) }
    private func refreshPreview() {
        guard let crop = pixelCrop else { preview = nil; needsDisplay = true; return }
        var items = history.items
        if let moving, let index = items.firstIndex(where: { $0.id == moving.id }) { items[index] = moving }
        if let draft { items.append(draft) }
        do { preview = try Renderer.render(source: source, crop: crop, items: items) }
        catch { showMessage(error.localizedDescription) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let active = activeRect
        if backdrop == nil {
            Renderer.drawImage(source, in: bounds)
            let dim = NSBezierPath(rect: bounds)
            if let active { dim.append(NSBezierPath(rect: active)) }
            dim.windingRule = .evenOdd; NSColor.black.withAlphaComponent(0.48).setFill(); dim.fill()
        }
        if let active {
            if let selection, let preview { Renderer.drawImage(preview, in: selection) }
            if !isEditor {
                if backdrop == nil { NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: active); path.lineWidth = 1.5; path.stroke() }
                if selection != nil && history.items.isEmpty {
                    // Eight round grips, corners and side midpoints, like the system screenshot tool.
                    for p in handles(active) {
                        let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                        NSColor.white.setFill(); dot.fill(); NSColor.black.withAlphaComponent(0.35).setStroke(); dot.lineWidth = 0.75; dot.stroke()
                    }
                }
            }
        }
        if let id = selectedID, let item = (moving.map { [$0] } ?? history.items).first(where: { $0.id == id }), let selection {
            let r = item.bounds
            let rect = CGRect(x: selection.minX + r.minX / scaleX, y: selection.minY + r.minY / scaleY, width: max(4, r.width / scaleX), height: max(4, r.height / scaleY)).insetBy(dx: -4, dy: -4)
            NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect: rect); outline.setLineDash([4, 3], count: 2, phase: 0); outline.stroke()
        }
        if selection == nil {
            let hint = "\(mode == .region ? "Drag to select an area, or click a window" : mode == .window ? "Click a visible window" : "Click to capture this display")  ·  Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
            hint.draw(at: CGPoint(x: (bounds.width - hint.size(withAttributes: attrs).width) / 2, y: 72), withAttributes: attrs)
        }
    }
    private func corners(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
    /// Corners 0–3 (clockwise from top-left), then side midpoints 4–7: top, right, bottom, left.
    private func handles(_ r: CGRect) -> [CGPoint] { corners(r) + [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)] }
    /// Which grip a point grabs: a corner or midpoint dot, or anywhere along a side.
    private func handle(at p: CGPoint, in r: CGRect) -> Int? {
        if let index = handles(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) { return index }
        let grip: CGFloat = 6, alongX = p.x > r.minX && p.x < r.maxX, alongY = p.y > r.minY && p.y < r.maxY
        if alongX && abs(p.y - r.minY) < grip { return 4 }
        if alongY && abs(p.x - r.maxX) < grip { return 5 }
        if alongX && abs(p.y - r.maxY) < grip { return 6 }
        if alongY && abs(p.x - r.minX) < grip { return 7 }
        return nil
    }
    private func resized(_ o: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        switch handle {
        case 0...3: Geometry.rect(corners(o)[(handle + 2) % 4], p)
        case 4: Geometry.rect(CGPoint(x: o.minX, y: p.y), CGPoint(x: o.maxX, y: o.maxY))
        case 5: Geometry.rect(CGPoint(x: o.minX, y: o.minY), CGPoint(x: p.x, y: o.maxY))
        case 6: Geometry.rect(CGPoint(x: o.minX, y: o.minY), CGPoint(x: o.maxX, y: p.y))
        default: Geometry.rect(CGPoint(x: p.x, y: o.minY), CGPoint(x: o.maxX, y: o.maxY))
        }
    }
    override func mouseMoved(with event: NSEvent) {
        pointer = clamped(convert(event.locationInWindow, from: nil))
        if selection == nil {
            // Cursor rects wait for the window to become key; keep the crosshair from the first movement.
            NSCursor.crosshair.set()
            hoveredWindow = mode == .display ? bounds : ((mode == .window || coordinator.preferences.value.autoSelectWindow) ? regions.first(where: { $0.rect.contains(pointer) })?.rect : nil)
            pointerChanged()
        }
    }
    override func mouseEntered(with event: NSEvent) { if selection == nil { window?.makeKey(); window?.makeFirstResponder(self) } }
    override func mouseDown(with event: NSEvent) {
        guard !coordinator.busy else { return }
        window?.makeFirstResponder(self); status.isHidden = true
        start = clamped(convert(event.locationInWindow, from: nil)); pointer = start
        guard let selection else { selecting = true; return }
        guard selection.insetBy(dx: -7, dy: -7).contains(start) else { return }
        if tool == .select {
            let point = pixelPoint(start)
            selectedID = history.items.reversed().first(where: { $0.bounds.insetBy(dx: -8 * scaleX, dy: -8 * scaleY).contains(point) })?.id
            moving = history.items.first { $0.id == selectedID }
            if event.clickCount == 2, let item = moving, item.tool == .text {
                moving = nil; beginText(at: item.points[0], existing: item); return
            }
            if !isEditor && moving == nil && history.items.isEmpty {
                originalSelection = selection
                resizeHandle = handle(at: start, in: selection)
            }
            needsDisplay = true; return
        }
        guard selection.contains(start) else { return }
        let point = pixelPoint(start)
        if tool == .text { beginText(at: point); return }
        var item = Annotation(tool: tool, points: [point, point], color: tool == .redact ? coordinator.preferences.value.redactColor : color, width: stroke, fontSize: fontSize)
        item.strength = strength
        if tool == .step { item.number = min(999, (history.items.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1) }
        draft = item; refreshPreview()
    }
    override func mouseDragged(with event: NSEvent) {
        guard !coordinator.busy else { return }
        pointer = clamped(convert(event.locationInWindow, from: nil))
        if selecting { pointerChanged(); return }
        if var moving, let original = history.items.first(where: { $0.id == moving.id }) {
            moving = original.moved(by: CGPoint(x: (pointer.x - start.x) * scaleX, y: (pointer.y - start.y) * scaleY)); self.moving = moving
        } else if let originalSelection {
            if let resizeHandle { selection = resized(originalSelection, handle: resizeHandle, to: pointer).intersection(bounds) }
            else {
                var moved = originalSelection.offsetBy(dx: pointer.x - start.x, dy: pointer.y - start.y)
                moved.origin.x = max(0, min(bounds.width - moved.width, moved.minX)); moved.origin.y = max(0, min(bounds.height - moved.height, moved.minY)); selection = moved
            }
            needsLayout = true
        } else if var item = draft {
            let point = pixelPoint(pointer)
            if tool == .pen || tool == .highlight { item.points.append(point) } else if tool != .step { item.points[1] = point }
            draft = item
        }
        refreshPreview()
    }
    override func mouseUp(with event: NSEvent) {
        guard !coordinator.busy else { return }
        pointer = clamped(convert(event.locationInWindow, from: nil))
        if selecting {
            selecting = false
            var rect = Geometry.rect(start, pointer)
            if mode == .display { rect = bounds }
            else if mode == .window || (rect.width < 3 && rect.height < 3 && coordinator.preferences.value.autoSelectWindow) { rect = regions.first(where: { $0.rect.contains(pointer) })?.rect ?? .zero }
            guard rect.width >= 2, rect.height >= 2 else { pointerChanged(); return }
            // Align selection geometry with the final physical-pixel crop.
            let crop = Geometry.pixelCrop(rect, viewSize: bounds.size, imageSize: CGSize(width: source.width, height: source.height))
            selection = CGRect(x: crop.minX / scaleX, y: crop.minY / scaleY, width: crop.width / scaleX, height: crop.height / scaleY)
            if let window = window as? CaptureWindow { coordinator.activate(window) }
            coordinator.selected(self)
            if window?.isVisible != true { return }
        } else if let moving {
            history.commit(history.items.map { $0.id == moving.id ? moving : $0 }); self.moving = nil
        } else if let draft {
            let meaningful = draft.tool == .step || draft.tool == .pen || draft.tool == .highlight || ((draft.tool == .line || draft.tool == .arrow) ? hypot(draft.bounds.width, draft.bounds.height) >= 3 : draft.bounds.width >= 2 && draft.bounds.height >= 2)
            if meaningful { history.commit(history.items + [draft]) }
            self.draft = nil
        }
        originalSelection = nil; resizeHandle = nil; refreshPreview(); updateControls()
    }
    private func beginText(at point: CGPoint, existing: Annotation? = nil) {
        commitText()
        textPoint = point; editingText = existing
        if let existing { color = existing.color; fontSize = existing.fontSize }
        let field = NSTextField(string: existing?.text ?? ""); field.placeholderString = "Type, then Return"; field.font = .systemFont(ofSize: fontSize / scaleX, weight: .semibold)
        field.textColor = NSColor(hex: color); field.backgroundColor = .textBackgroundColor; field.delegate = self
        guard let selection else { return }
        field.frame = CGRect(x: selection.minX + point.x / scaleX, y: selection.minY + point.y / scaleY, width: min(300, selection.maxX - start.x), height: max(28, fontSize / scaleX * 1.5))
        addSubview(field); textField = field; window?.makeFirstResponder(field)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) { commitText(); return true }
        if commandSelector == #selector(cancelOperation(_:)) { textField?.removeFromSuperview(); textField = nil; editingText = nil; window?.makeFirstResponder(self); return true }
        return false
    }
    private func commitText() {
        guard let field = textField else { return }
        if !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            var item = editingText ?? Annotation(tool: .text, points: [textPoint], color: color, width: stroke, fontSize: fontSize); item.text = field.stringValue
            if editingText != nil { history.commit(history.items.map { $0.id == item.id ? item : $0 }) }
            else { history.commit(history.items + [item]) }
        }
        field.removeFromSuperview(); textField = nil; editingText = nil; window?.makeFirstResponder(self); refreshPreview(); updateControls()
    }
    func showMessage(_ message: String) { status.stringValue = " \(message) "; status.isHidden = false; needsLayout = true; NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
    @objc private func changeMode(_ sender: NSButton) {
        setCaptureMode(CaptureMode.allCases[sender.tag])
    }
    private func setCaptureMode(_ mode: CaptureMode) {
        self.mode = mode; hoveredWindow = nil; updateControls()
        if mode == .display, window != nil {
            selection = bounds
            coordinator.selected(self)
        }
    }
    /// Names each control the instant the pointer reaches it, on the side facing away from the selection.
    private func showHint(for button: ToolButton, _ inside: Bool) {
        if isEditor {
            onEditorHover?(button, inside)
            return
        }
        guard inside, !button.hint.isEmpty, let bar = button.superview, !bar.isHidden else { hoverLabel.isHidden = true; return }
        hoverLabel.stringValue = button.hint
        let size = CGSize(width: ceil(hoverLabel.intrinsicContentSize.width) + 16, height: 22)
        let frame = convert(button.bounds, from: button)
        var origin: CGPoint
        if bar === toolBar {
            let onRight = toolBar.frame.minX > (selection?.maxX ?? 0)
            origin = CGPoint(x: onRight ? toolBar.frame.maxX + 8 : toolBar.frame.minX - size.width - 8, y: frame.midY - size.height / 2)
            if origin.x + size.width > bounds.width - 4 || origin.x < 4 { origin.x = onRight ? toolBar.frame.minX - size.width - 8 : toolBar.frame.maxX + 8 }
        } else {
            origin = CGPoint(x: frame.midX - size.width / 2, y: bar.frame.maxY + 6)
            if origin.y + size.height > bounds.height - 4 { origin.y = bar.frame.minY - size.height - 6 }
        }
        origin.x = max(4, min(bounds.width - size.width - 4, origin.x))
        hoverLabel.frame = CGRect(origin: origin, size: size); hoverLabel.isHidden = false
    }
    @objc private func changeTool(_ sender: NSButton) {
        let variant = groupVariant[sender.tag]
        // Clicking the active grouped tool again offers its other variants.
        if variant == tool, Self.toolGroups[sender.tag].tools.count > 1, let menu = sender.menu {
            menu.items.forEach { $0.state = ($0.representedObject as? String) == tool.rawValue ? .on : .off }
            menu.popUp(positioning: nil, at: CGPoint(x: sender.bounds.maxX + 6, y: sender.bounds.minY), in: sender); return
        }
        select(variant)
    }
    private func select(_ newTool: Tool) {
        commitText()
        if let group = Self.toolGroups.firstIndex(where: { $0.tools.contains(newTool) }) { groupVariant[group] = newTool }
        tool = newTool; selectedID = nil; updateControls(); privacyHint()
    }
    private func variantMenu(for group: Int) -> NSMenu {
        let menu = NSMenu()
        for variant in Self.toolGroups[group].tools {
            let item = NSMenuItem(title: variant.title, action: #selector(pickVariant(_:)), keyEquivalent: variant.key)
            item.keyEquivalentModifierMask = []; item.target = self; item.representedObject = variant.rawValue
            item.image = NSImage(systemSymbolName: variant.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }
    @objc private func pickVariant(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let picked = Tool(rawValue: raw) { select(picked) } }
    private func privacyHint() {
        if tool == .redact { showMessage("Redact permanently replaces pixels in copied and saved images.") }
        else if tool == .blur || tool == .pixelate { showMessage("Visual effect only. Use Redact to protect private information.") }
        else { status.isHidden = true }
    }
    @objc private func output(_ sender: NSButton) { commitText(); coordinator.export(self, action: [OutputAction.quickSave, .ocr, .save, .copy, .pin][sender.tag]) }
    @objc private func cancelCapture() { coordinator.cancel() }
    @objc private func undoEdit() { history.undo(); selectedID = nil; refreshPreview(); updateControls() }
    @objc private func redoEdit() { history.redo(); selectedID = nil; refreshPreview(); updateControls() }
    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let id = selectedID, let index = history.items.firstIndex(where: { $0.id == id }) else { return }
        var items = history.items; change(&items[index]); history.commit(items); refreshPreview(); updateControls()
    }
    private func makeStylePopover() -> NSPopover {
        colorWell.target = self; colorWell.action = #selector(colorChanged(_:)); colorWell.setAccessibilityLabel("Annotation colour")
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        var rows: [[NSView]] = [[popoverLabel("Colour"), colorWell]]
        for (title, range, action) in [("Stroke", 1.0...30.0, #selector(widthChanged(_:))), ("Text", 10.0...120.0, #selector(fontChanged(_:))), ("Effect", 2.0...50.0, #selector(strengthChanged(_:)))] {
            let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
            slider.controlSize = .small; slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            slider.setAccessibilityLabel(title == "Effect" ? "Blur or pixelate strength" : title == "Text" ? "Text size" : "Stroke width")
            styleSliders.append(slider); rows.append([popoverLabel(title), slider])
        }
        let grid = NSGridView(views: rows); grid.rowSpacing = 10; grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing; grid.rowAlignment = .firstBaseline
        let container = NSView(); grid.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 14), grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
                                     grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)])
        let controller = NSViewController(); controller.view = container
        let popover = NSPopover(); popover.contentViewController = controller; popover.behavior = .transient; popover.animates = true
        return popover
    }
    private func popoverLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: NSFont.smallSystemFontSize); label.textColor = .secondaryLabelColor
        return label
    }
    @objc private func showStyle(_ sender: NSButton) {
        if stylePopover.isShown { stylePopover.performClose(nil); return }
        commitText()
        _ = stylePopover.contentViewController?.view
        colorWell.color = NSColor(hex: color)
        for (slider, value) in zip(styleSliders, [stroke, fontSize, strength]) { slider.doubleValue = value }
        stylePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: isEditor ? .maxY : (toolBar.frame.minX > (selection?.maxX ?? 0) ? .maxX : .minX))
    }
    @objc private func colorChanged(_ sender: NSColorWell) {
        color = sender.color.hex
        if tool == .redact { coordinator.preferences.value.redactColor = color }
        styleButton.contentTintColor = .black
        updateSelected { $0.color = color }
    }
    @objc private func widthChanged(_ sender: NSSlider) { stroke = sender.doubleValue; updateSelected { $0.width = stroke } }
    @objc private func fontChanged(_ sender: NSSlider) { fontSize = sender.doubleValue; updateSelected { $0.fontSize = fontSize } }
    @objc private func strengthChanged(_ sender: NSSlider) { strength = sender.doubleValue; updateSelected { $0.strength = strength } }
    override func keyDown(with event: NSEvent) {
        guard !coordinator.busy else { if event.keyCode == 53 { coordinator.cancel() }; return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { coordinator.cancel(); return }
        if selection == nil {
            if let index = Int(key), (1...3).contains(index) { setCaptureMode(CaptureMode.allCases[index - 1]) }
            return
        }
        if event.modifierFlags.contains(.command) {
            switch key {
            case "c": coordinator.export(self, action: event.modifierFlags.contains(.shift) ? .ocr : .copy)
            case "s": coordinator.export(self, action: event.modifierFlags.contains(.shift) ? .quickSave : .save)
            case "p": commitText(); coordinator.export(self, action: .pin)
            case "z": if event.modifierFlags.contains(.shift) { redoEdit() } else { undoEdit() }
            default: super.keyDown(with: event)
            }
        } else if event.keyCode == 51 || event.keyCode == 117 {
            if let selectedID { history.commit(history.items.filter { $0.id != selectedID }); self.selectedID = nil; refreshPreview(); updateControls() }
        } else if let tool = Tool.allCases.first(where: { $0.key == key }) { select(tool) }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textField != nil { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), ["c", "s", "z", "p"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Tool bar button; grouped tools get a small corner triangle, as in Apple's own tool palettes.
final class ToolButton: NSButton {
    var usesBlackGlyphs = false
    var dimsWhenUnavailable = false
    var hasVariants = false { didSet { needsDisplay = true } }
    var hint = ""
    var onHover: ((ToolButton, Bool) -> Void)?
    private(set) var hovered = false
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    /// Hover, press and selection share one tile, inset so neighbouring tiles never touch.
    private var tileRect: CGRect { bounds.insetBy(dx: 4, dy: 3) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; onHover?(self, true) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; onHover?(self, false) }
    override func draw(_ dirtyRect: NSRect) {
        if usesBlackGlyphs {
            // Keep enabled glyphs black during tracking; history buttons become
            // grey when their action is unavailable.
            let pressed = cell?.isHighlighted == true, selected = state == .on
            if pressed || hovered || selected {
                let alpha: CGFloat = pressed ? 0.16 : selected ? (hovered ? 0.13 : 0.1) : 0.06
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: tileRect, xRadius: 6, yRadius: 6).fill()
            }
            if let symbol = image?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) {
                let black = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    NSColor.black.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
                black.draw(in: CGRect(x: (bounds.width - symbol.size.width) / 2,
                                      y: (bounds.height - symbol.size.height) / 2,
                                      width: symbol.size.width, height: symbol.size.height),
                           from: .zero, operation: .sourceOver,
                           fraction: dimsWhenUnavailable && !isEnabled ? 0.3 : 1,
                           respectFlipped: true, hints: nil)
            }
        } else {
            super.draw(dirtyRect)
        }
        guard hasVariants else { return }
        let r = usesBlackGlyphs ? tileRect : bounds, size: CGFloat = 4, inset: CGFloat = 2.5
        let corner = NSBezierPath()
        corner.move(to: CGPoint(x: r.maxX - inset, y: isFlipped ? r.maxY - inset : r.minY + inset))
        corner.line(to: CGPoint(x: r.maxX - inset - size, y: isFlipped ? r.maxY - inset : r.minY + inset))
        corner.line(to: CGPoint(x: r.maxX - inset, y: isFlipped ? r.maxY - inset - size : r.minY + inset + size))
        corner.close()
        (usesBlackGlyphs ? NSColor.black : (state == .on ? NSColor.white : NSColor.secondaryLabelColor)).setFill(); corner.fill()
    }
}
