import AppKit

/// Windowed presentation of the same pixel-based annotation canvas used by area capture.
final class CaptureEditorView: NSView {
    let canvas: CaptureView
    private let header = NSView()
    private let hoverHint = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let document = CheckerboardView()
    private let actions: NSStackView
    private let tools: NSStackView
    private let dimensions = NSTextField(labelWithString: "")
    private let zoom = NSPopUpButton()
    private let backingScale: CGFloat
    override var isFlipped: Bool { true }

    init(frame: CGRect, source: CGImage, coordinator: CaptureCoordinator, backingScale: CGFloat) {
        self.backingScale = backingScale
        canvas = CaptureView(frame: CGRect(x: 0, y: 0, width: source.width, height: source.height), source: source,
                             regions: [], mode: .display, coordinator: coordinator, isEditor: true)
        canvas.selection = canvas.bounds
        let controls = canvas.editorControls()
        actions = controls.actions
        tools = controls.tools
        super.init(frame: frame)
        header.appearance = NSAppearance(named: .aqua)
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        addSubview(header)
        header.addSubview(actions)
        header.addSubview(tools)
        dimensions.stringValue = "\(source.width) × \(source.height) px\nImage size"
        dimensions.font = .systemFont(ofSize: 11, weight: .medium)
        dimensions.textColor = .black
        header.addSubview(dimensions)
        zoom.addItems(withTitles: ["Fit", "50%", "100%", "200%"])
        zoom.target = self
        zoom.action = #selector(changeZoom)
        zoom.setAccessibilityLabel("Screenshot zoom")
        header.addSubview(zoom)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        document.addSubview(canvas)
        addSubview(scrollView)
        hoverHint.font = .systemFont(ofSize: 12, weight: .medium)
        hoverHint.textColor = .white
        hoverHint.wantsLayer = true
        hoverHint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        hoverHint.layer?.cornerRadius = 6
        hoverHint.alignment = .center
        hoverHint.isHidden = true
        addSubview(hoverHint)
        canvas.onEditorHover = { [weak self] button, inside in
            guard let self else { return }
            guard inside else { hoverHint.isHidden = true; return }
            hoverHint.stringValue = button.hint
            let width = min(bounds.width - 16, ceil(hoverHint.intrinsicContentSize.width) + 20)
            let buttonRect = convert(button.bounds, from: button)
            hoverHint.frame = CGRect(x: max(8, min(bounds.width - width - 8, buttonRect.midX - width / 2)),
                                     y: header.frame.maxY + 6, width: width, height: 26)
            hoverHint.isHidden = false
        }
        setAccessibilityLabel("Screenshot editor with annotation toolbar")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func changeZoom() { needsLayout = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            header.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        }
    }
    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 64
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let actionWidth = ceil(actions.fittingSize.width)
        actions.frame = CGRect(x: 8, y: 10, width: actionWidth, height: 44)
        let toolWidth = ceil(tools.fittingSize.width)
        tools.frame = CGRect(x: actionWidth + 20, y: 10, width: toolWidth, height: 44)
        let infoX = actionWidth + toolWidth + 32
        dimensions.frame = CGRect(x: infoX, y: 17, width: 135, height: 34)
        zoom.frame = CGRect(x: infoX + 140, y: 18, width: 100, height: 28)
        scrollView.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(1, bounds.height - headerHeight))
        let viewport = scrollView.contentSize
        let image = CGSize(width: canvas.source.width, height: canvas.source.height)
        let fit = min(1 / backingScale, max(1, viewport.width - 32) / image.width, max(1, viewport.height - 32) / image.height)
        let scale: CGFloat = switch zoom.indexOfSelectedItem {
        case 1: 0.5
        case 2: 1
        case 3: 2
        default: fit
        }
        zoom.item(at: 0)?.title = "Fit · \(Int((fit * 100).rounded()))%"
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        document.setFrameSize(CGSize(width: max(viewport.width, size.width + 32), height: max(viewport.height, size.height + 32)))
        canvas.resizeEditorCanvas(to: size)
        canvas.setFrameOrigin(CGPoint(x: (document.bounds.width - size.width) / 2, y: (document.bounds.height - size.height) / 2))
    }
}

private final class CheckerboardView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.19, alpha: 1).setFill()
        dirtyRect.fill()
        NSColor(white: 0.23, alpha: 1).setFill()
        let tile: CGFloat = 12
        for row in Int(floor(dirtyRect.minY / tile))...Int(ceil(dirtyRect.maxY / tile)) {
            for column in Int(floor(dirtyRect.minX / tile))...Int(ceil(dirtyRect.maxX / tile)) where (row + column).isMultiple(of: 2) {
                CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile).fill()
            }
        }
    }
}
