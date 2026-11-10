import AppKit

/// A non-activating panel lets the user keep scrolling the underlying application.
final class CapturePreview: NSPanel {
    private let stack = PreviewStackView()
    private let actions = NSStackView()
    private let imageView = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var handlers: [() -> Void] = []
    private var dismissal: Task<Void, Never>?
    private var timeout: Double?
    private var pointerInside = false
    var onClose: (() -> Void)?

    init(image: CGImage, instruction: String = "") {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 340, height: 280), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; title = "FastShot Preview"; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Screenshot preview")
        actions.spacing = 8
        // Proportional widths keep four labels, such as Quick Save, inside the fixed preview width.
        actions.distribution = .fillProportionally
        stack.onHover = { [weak self] inside in
            guard let self else { return }
            pointerInside = inside
            scheduleDismissal()
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([imageView.widthAnchor.constraint(equalToConstant: 310), imageView.heightAnchor.constraint(equalToConstant: 160)])
        status.stringValue = instruction; status.preferredMaxLayoutWidth = 310
        status.isHidden = instruction.isEmpty
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(imageView); stack.addArrangedSubview(status); stack.addArrangedSubview(actions)
        contentView = stack; updateImage(image)
    }
    func updateImage(_ image: CGImage) {
        imageView.image = NSImage(cgImage: image, size: .zero)
        title = "Screenshot · \(image.width) × \(image.height)"
    }
    func showStatus(_ text: String, isError: Bool = false) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
        status.isHidden = false
        NSAccessibility.post(element: status, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func showError(_ text: String) { showStatus(text, isError: true) }
    func addButton(_ title: String, action: @escaping () -> Void) {
        let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(title)
        button.tag = handlers.count; handlers.append(action); actions.addArrangedSubview(button)
    }
    @objc private func clicked(_ sender: NSButton) { handlers[sender.tag]() }
    func present(timeout: Double? = nil) {
        if let screen = NSScreen.main {
            setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - frame.width - 20, y: screen.visibleFrame.minY + 20))
        }
        orderFrontRegardless()
        self.timeout = timeout
        pointerInside = frame.contains(NSEvent.mouseLocation)
        scheduleDismissal()
    }
    private func scheduleDismissal() {
        dismissal?.cancel(); dismissal = nil
        guard let timeout, !pointerInside else { return }
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }
    override func close() { dismissal?.cancel(); dismissal = nil; onClose?(); onClose = nil; super.close() }
}

private final class PreviewStackView: NSStackView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

nonisolated enum ScrollStitcher {
    /// Match the previous bottom against the new top, then append only new rows.
    @concurrent static func append(_ previous: CGImage, _ next: CGImage) async throws -> CGImage {
        try Task.checkCancellation()
        let (combinedHeight, heightOverflow) = previous.height.addingReportingOverflow(next.height)
        let (combinedPixels, pixelOverflow) = previous.width.multipliedReportingOverflow(by: combinedHeight)
        guard previous.width == next.width, next.height >= 32, !heightOverflow, combinedHeight <= 32000,
              !pixelOverflow, combinedPixels <= 40_000_000 else {
            throw FastShotError.message("Capture dimensions changed or the image is too large. Finish this capture first.")
        }
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let (pixelCount, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
            let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            guard !pixelOverflow, !byteOverflow else {
                throw FastShotError.message("The scrolling capture is too large to process.")
            }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let rendered = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard rendered else { throw FastShotError.message("The scrolling capture is too large to process.") }
            return bytes
        }
        let maximumOverlap = min(previous.height, next.height)
        guard let previousTail = previous.cropping(to: CGRect(x: 0, y: previous.height - maximumOverlap,
                                                               width: previous.width, height: maximumOverlap)) else {
            throw FastShotError.message("Could not prepare screenshots for stitching.")
        }
        let a = try pixels(previousTail)
        try Task.checkCancellation()
        let b = try pixels(next), width = next.width
        var best = Double.infinity, overlap = 0
        let minimum = max(16, next.height / 4)
        for rows in minimum...maximumOverlap {
            if rows.isMultiple(of: 64) { try Task.checkCancellation() }
            var difference = 0.0, samples = 0
            for y in stride(from: 0, to: rows, by: max(1, rows / 32)) {
                for x in stride(from: width / 10, to: max(width / 10 + 1, width * 9 / 10), by: max(1, width / 64)) {
                    for channel in 0..<3 {
                        difference += abs(Double(a[((maximumOverlap - rows + y) * width + x) * 4 + channel]) - Double(b[(y * width + x) * 4 + channel])); samples += 1
                    }
                }
            }
            let score = difference / Double(samples)
            if score <= best { best = score; overlap = rows }
        }
        guard best < 8, overlap < next.height else { throw FastShotError.message("No new matching content. Scroll less, keep the area still, and try again.") }
        try Task.checkCancellation()
        let height = previous.height + next.height - overlap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let tail = next.cropping(to: CGRect(x: 0, y: overlap, width: width, height: next.height - overlap)) else { throw FastShotError.message("Could not stitch screenshots.") }
        context.draw(previous, in: CGRect(x: 0, y: height - previous.height, width: width, height: previous.height))
        context.draw(tail, in: CGRect(x: 0, y: 0, width: width, height: next.height - overlap))
        guard let result = context.makeImage() else { throw FastShotError.message("Could not create scrolling screenshot.") }
        try Task.checkCancellation()
        return result
    }
}
