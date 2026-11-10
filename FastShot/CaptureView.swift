import AppKit

final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    init(screen: NSScreen, source: CGImage, regions: [WindowRegion], mode: CaptureMode, coordinator: CaptureCoordinator) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false; level = .screenSaver; backgroundColor = .clear; isOpaque = false; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = CaptureView(frame: CGRect(origin: .zero, size: screen.frame.size), source: source, regions: regions, mode: mode, coordinator: coordinator)
        contentView = view; makeFirstResponder(view)
        setAccessibilityLabel("FastShot capture overlay")
    }
}

final class CaptureView: NSView, NSTextFieldDelegate {
    let source: CGImage
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
    private var resizeCorner: Int?
    private var selecting = false
    private var hoveredWindow: CGRect?
    private var preview: CGImage?
    private lazy var sourceBitmap = NSBitmapImageRep(cgImage: source)
    private var modeBar = NSStackView()
    private var toolBar = NSStackView()
    private var actionBar = NSStackView()
    private var styleBar = NSStackView()
    private var toolButtons: [Tool: NSButton] = [:]
    private var undoButton: NSButton!
    private var redoButton: NSButton!
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
    var pixelCrop: CGRect? {
        selection.map { Geometry.pixelCrop($0, viewSize: bounds.size, imageSize: CGSize(width: source.width, height: source.height)) }
    }
    private var scaleX: CGFloat { CGFloat(source.width) / bounds.width }
    private var scaleY: CGFloat { CGFloat(source.height) / bounds.height }

    init(frame: CGRect, source: CGImage, regions: [WindowRegion], mode: CaptureMode, coordinator: CaptureCoordinator) {
        self.source = source; self.regions = regions; self.mode = mode; self.coordinator = coordinator
        color = coordinator.preferences.value.annotationColor; stroke = coordinator.preferences.value.strokeWidth; fontSize = coordinator.preferences.value.fontSize
        super.init(frame: frame)
        setupControls()
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Capture area. Drag to select. Escape cancels. Keys 1, 2, 3 change capture mode.")
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .select && selection != nil ? .arrow : .crosshair) }
    private func button(_ label: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        b.bezelStyle = .inline; b.isBordered = false; b.toolTip = label; b.setAccessibilityLabel(label)
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true; b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }
    private func panel(_ stack: NSStackView, vertical: Bool = false) {
        stack.orientation = vertical ? .vertical : .horizontal; stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.wantsLayer = true; stack.layer?.cornerRadius = 7; stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.gray.cgColor; stack.layer?.shadowOpacity = 0.22; stack.layer?.shadowRadius = 5
        addSubview(stack)
    }
    private func setupControls() {
        panel(modeBar)
        for (index, mode) in CaptureMode.allCases.enumerated() {
            let b = NSButton(title: "\(mode.title)  \(index + 1)", target: self, action: #selector(changeMode(_:)))
            b.tag = index; b.bezelStyle = .recessed; b.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading
            modeBar.addArrangedSubview(b)
        }
        panel(toolBar, vertical: true)
        for (index, tool) in Tool.allCases.enumerated() {
            let b = button("\(tool.title) (\(tool.key.uppercased()))", symbol: tool.symbol, action: #selector(changeTool(_:)))
            b.tag = index; toolBar.addArrangedSubview(b); toolButtons[tool] = b
        }
        undoButton = button("Undo (⌘Z)", symbol: "arrow.uturn.backward", action: #selector(undoEdit))
        redoButton = button("Redo (⌘⇧Z)", symbol: "arrow.uturn.forward", action: #selector(redoEdit))
        toolBar.addArrangedSubview(undoButton); toolBar.addArrangedSubview(redoButton)
        panel(actionBar)
        for (label, symbol, action) in [("Quick save (⌘⇧S)", "bolt", OutputAction.quickSave), ("Copy text (⌘⇧C)", "text.viewfinder", .ocr), ("Save as (⌘S)", "square.and.arrow.down", .save), ("Copy (⌘C)", "square.on.square", .copy)] {
            let b = button(label, symbol: symbol, action: #selector(output(_:)))
            b.tag = switch action { case .quickSave: 0; case .ocr: 1; case .save: 2; case .copy: 3 }
            actionBar.addArrangedSubview(b)
        }
        actionBar.addArrangedSubview(button("Cancel (Esc)", symbol: "xmark", action: #selector(cancelCapture)))
        panel(styleBar)
        let well = NSColorWell(); well.color = NSColor(hex: color); well.target = self; well.action = #selector(colorChanged(_:)); well.setAccessibilityLabel("Annotation colour")
        well.widthAnchor.constraint(equalToConstant: 35).isActive = true
        styleBar.addArrangedSubview(well)
        let slider = NSSlider(value: stroke, minValue: 1, maxValue: 30, target: self, action: #selector(widthChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 55).isActive = true; slider.setAccessibilityLabel("Stroke width")
        styleBar.addArrangedSubview(styleLabel("Stroke"))
        styleBar.addArrangedSubview(slider)
        let textSize = NSSlider(value: fontSize, minValue: 10, maxValue: 120, target: self, action: #selector(fontChanged(_:)))
        textSize.widthAnchor.constraint(equalToConstant: 55).isActive = true; textSize.setAccessibilityLabel("Text size")
        styleBar.addArrangedSubview(styleLabel("Text"))
        styleBar.addArrangedSubview(textSize)
        let effect = NSSlider(value: strength, minValue: 2, maxValue: 50, target: self, action: #selector(strengthChanged(_:)))
        effect.widthAnchor.constraint(equalToConstant: 55).isActive = true; effect.setAccessibilityLabel("Blur or pixelate strength")
        styleBar.addArrangedSubview(styleLabel("Effect"))
        styleBar.addArrangedSubview(effect)
        status.textColor = .white; status.backgroundColor = NSColor.black.withAlphaComponent(0.8); status.drawsBackground = true
        status.font = .monospacedSystemFont(ofSize: 12, weight: .medium); status.isHidden = true; addSubview(status)
        updateControls()
    }
    private func styleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
        return label
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateControls() }
    private func updateControls() {
        let editing = selection != nil
        for stack in [modeBar, toolBar, actionBar, styleBar] { stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        modeBar.isHidden = editing; toolBar.isHidden = !editing; actionBar.isHidden = !editing; styleBar.isHidden = !editing
        for (kind, button) in toolButtons { button.contentTintColor = kind == tool ? .controlAccentColor : .labelColor; button.state = kind == tool ? .on : .off }
        undoButton?.isEnabled = history.canUndo; redoButton?.isEnabled = history.canRedo
        for (index, view) in modeBar.arrangedSubviews.enumerated() { (view as? NSButton)?.state = CaptureMode.allCases[index] == mode ? .on : .off }
        needsLayout = true; needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
    override func layout() {
        super.layout()
        modeBar.frame = CGRect(x: (bounds.width - 340) / 2, y: 20, width: 340, height: 40)
        guard let selection else { return }
        let toolHeight: CGFloat = 430
        let right = selection.maxX + 10
        toolBar.frame = CGRect(x: right + 42 <= bounds.width ? right : max(8, selection.minX - 52), y: max(8, min(selection.minY, bounds.height - toolHeight - 8)), width: 42, height: toolHeight)
        actionBar.frame = CGRect(x: max(8, min(selection.maxX - 170, bounds.width - 178)), y: min(bounds.height - 46, selection.maxY + 10), width: 170, height: 38)
        styleBar.frame = CGRect(x: max(8, min(selection.minX, bounds.width - 325)), y: selection.minY > 52 ? selection.minY - 48 : min(bounds.height - 46, selection.maxY + 54), width: 325, height: 38)
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
        Renderer.drawImage(source, in: bounds)
        let active = selection ?? (selecting ? Geometry.rect(start, pointer) : hoveredWindow)
        let dim = NSBezierPath(rect: bounds)
        if let active { dim.append(NSBezierPath(rect: active)) }
        dim.windingRule = .evenOdd; NSColor.black.withAlphaComponent(0.48).setFill(); dim.fill()
        if let active {
            if let selection, let preview { Renderer.drawImage(preview, in: selection) }
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: active); path.lineWidth = 1.5; path.stroke()
            let dimensions = Geometry.pixelCrop(active, viewSize: bounds.size, imageSize: CGSize(width: source.width, height: source.height))
            let label = " \(Int(dimensions.width)) × \(Int(dimensions.height)) " as NSString
            label.draw(at: CGPoint(x: active.minX, y: max(4, active.minY - 23)), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.8)])
            if selection != nil && history.items.isEmpty {
                for p in corners(active) { NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill() }
            }
        }
        if let id = selectedID, let item = (moving.map { [$0] } ?? history.items).first(where: { $0.id == id }), let selection {
            let r = item.bounds
            let rect = CGRect(x: selection.minX + r.minX / scaleX, y: selection.minY + r.minY / scaleY, width: max(4, r.width / scaleX), height: max(4, r.height / scaleY)).insetBy(dx: -4, dy: -4)
            NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect: rect); outline.setLineDash([4, 3], count: 2, phase: 0); outline.stroke()
        }
        if selection == nil && coordinator.preferences.value.showMagnifier { drawMagnifier() }
        if selection == nil {
            let hint = "\(mode == .region ? "Drag to select an area, or click a window" : mode == .window ? "Click a visible window" : "Click to capture this display")  ·  Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
            hint.draw(at: CGPoint(x: (bounds.width - hint.size(withAttributes: attrs).width) / 2, y: 72), withAttributes: attrs)
        }
    }
    private func drawMagnifier() {
        let pixel = CGPoint(x: pointer.x * scaleX, y: pointer.y * scaleY)
        let sample = CGRect(x: max(0, min(CGFloat(source.width) - 20, pixel.x - 10)), y: max(0, min(CGFloat(source.height) - 20, pixel.y - 10)), width: 20, height: 20)
        guard let zoom = source.cropping(to: sample) else { return }
        let rect = CGRect(x: min(bounds.width - 130, pointer.x + 22), y: min(bounds.height - 150, pointer.y + 22), width: 110, height: 110)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.imageInterpolation = .none
        Renderer.drawImage(zoom, in: rect); NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke(); NSBezierPath(rect: rect).stroke()
        let cross = NSBezierPath(); cross.move(to: CGPoint(x: rect.midX - 8, y: rect.midY)); cross.line(to: CGPoint(x: rect.midX + 8, y: rect.midY)); cross.move(to: CGPoint(x: rect.midX, y: rect.midY - 8)); cross.line(to: CGPoint(x: rect.midX, y: rect.midY + 8)); cross.stroke()
        let sampleRep = sourceBitmap
        let hex = sampleRep.colorAt(x: max(0, min(source.width - 1, Int(pixel.x))), y: max(0, min(source.height - 1, Int(pixel.y))))?.hex ?? ""
        ("\(Int(pixel.x)), \(Int(pixel.y)) \(hex)" as NSString).draw(at: CGPoint(x: rect.minX, y: rect.maxY + 4), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black])
    }
    private func corners(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
    override func mouseMoved(with event: NSEvent) {
        pointer = clamped(convert(event.locationInWindow, from: nil))
        if selection == nil {
            hoveredWindow = mode == .display ? bounds : ((mode == .window || coordinator.preferences.value.autoSelectWindow) ? regions.first(where: { $0.rect.contains(pointer) })?.rect : nil)
            needsDisplay = true
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
            if moving == nil && history.items.isEmpty {
                originalSelection = selection
                resizeCorner = corners(selection).firstIndex(where: { hypot($0.x - start.x, $0.y - start.y) < 10 })
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
        if selecting { needsDisplay = true; return }
        if var moving, let original = history.items.first(where: { $0.id == moving.id }) {
            moving = original.moved(by: CGPoint(x: (pointer.x - start.x) * scaleX, y: (pointer.y - start.y) * scaleY)); self.moving = moving
        } else if let originalSelection {
            if let corner = resizeCorner { let opposite = corners(originalSelection)[(corner + 2) % 4]; selection = Geometry.rect(opposite, pointer).intersection(bounds) }
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
            guard rect.width >= 2, rect.height >= 2 else { needsDisplay = true; return }
            // Align selection geometry with the final physical-pixel crop.
            let crop = Geometry.pixelCrop(rect, viewSize: bounds.size, imageSize: CGSize(width: source.width, height: source.height))
            selection = CGRect(x: crop.minX / scaleX, y: crop.minY / scaleY, width: crop.width / scaleX, height: crop.height / scaleY)
            if let window = window as? CaptureWindow { coordinator.activate(window) }
        } else if let moving {
            history.commit(history.items.map { $0.id == moving.id ? moving : $0 }); self.moving = nil
        } else if let draft {
            let meaningful = draft.tool == .step || draft.tool == .pen || draft.tool == .highlight || ((draft.tool == .line || draft.tool == .arrow) ? hypot(draft.bounds.width, draft.bounds.height) >= 3 : draft.bounds.width >= 2 && draft.bounds.height >= 2)
            if meaningful { history.commit(history.items + [draft]) }
            self.draft = nil
        }
        originalSelection = nil; resizeCorner = nil; refreshPreview(); updateControls()
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
    @objc private func changeMode(_ sender: NSButton) { mode = CaptureMode.allCases[sender.tag]; hoveredWindow = nil; updateControls() }
    @objc private func changeTool(_ sender: NSButton) { commitText(); tool = Tool.allCases[sender.tag]; selectedID = nil; updateControls(); privacyHint() }
    private func privacyHint() {
        if tool == .redact { showMessage("Redact permanently replaces pixels in copied and saved images.") }
        else if tool == .blur || tool == .pixelate { showMessage("Visual effect only. Use Redact to protect private information.") }
        else { status.isHidden = true }
    }
    @objc private func output(_ sender: NSButton) { commitText(); coordinator.export(self, action: [OutputAction.quickSave, .ocr, .save, .copy][sender.tag]) }
    @objc private func cancelCapture() { coordinator.cancel() }
    @objc private func undoEdit() { history.undo(); selectedID = nil; refreshPreview(); updateControls() }
    @objc private func redoEdit() { history.redo(); selectedID = nil; refreshPreview(); updateControls() }
    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let id = selectedID, let index = history.items.firstIndex(where: { $0.id == id }) else { return }
        var items = history.items; change(&items[index]); history.commit(items); refreshPreview(); updateControls()
    }
    @objc private func colorChanged(_ sender: NSColorWell) {
        color = sender.color.hex
        if tool == .redact { coordinator.preferences.value.redactColor = color }
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
            if let index = Int(key), (1...3).contains(index) { mode = CaptureMode.allCases[index - 1]; updateControls() }
            return
        }
        if event.modifierFlags.contains(.command) {
            switch key {
            case "c": coordinator.export(self, action: event.modifierFlags.contains(.shift) ? .ocr : .copy)
            case "s": coordinator.export(self, action: event.modifierFlags.contains(.shift) ? .quickSave : .save)
            case "z": if event.modifierFlags.contains(.shift) { redoEdit() } else { undoEdit() }
            default: super.keyDown(with: event)
            }
        } else if event.keyCode == 51 || event.keyCode == 117 {
            if let selectedID { history.commit(history.items.filter { $0.id != selectedID }); self.selectedID = nil; refreshPreview(); updateControls() }
        } else if let tool = Tool.allCases.first(where: { $0.key == key }) { self.tool = tool; selectedID = nil; updateControls(); privacyHint() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textField != nil { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), ["c", "s", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}
