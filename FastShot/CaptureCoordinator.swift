import AppKit
import Observation
import ScreenCaptureKit
import Vision
import UniformTypeIdentifiers

@Observable final class CaptureCoordinator {
    let preferences: PreferencesStore
    private(set) var captureFeedbackProgress: Double?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    var busy = false
    var message: String?
    var permissionNeeded = false
    private(set) var screenAccessGranted = false
    @ObservationIgnored var reopenSettings: (() -> Void)?
    private var command: CaptureCommand = .capture
    private var lastArea: (display: CGDirectDisplayID, rect: CGRect)?
    private var previewPanel: CapturePreview?
    /// Floating pins outlive captures; each removes itself when closed.
    private(set) var pins: [PinnedImageWindow] = []
    private var scrollImage: CGImage?
    private var scrollRegion: (display: CGDirectDisplayID, crop: CGRect)?
    private var overlays: [CaptureWindow] = []
    private var previousApp: NSRunningApplication?
    private var settingsWasVisible = false
    private var task: Task<Void, Never>?
    private var session = UUID()
    private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let permissionPreflight: @MainActor () -> Bool
    @ObservationIgnored private let permissionRequest: @MainActor () async throws -> Void

    init(preferences: PreferencesStore,
         permissionPreflight: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         permissionRequest: @escaping @MainActor () async throws -> Void = {
        _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }) {
        self.preferences = preferences
        self.permissionRequest = permissionRequest
        self.permissionPreflight = permissionPreflight
        refreshScreenPermission()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        })
    }
    func perform(_ command: CaptureCommand) {
        if command == .showApp { showSettings(); return }
        guard !busy, overlays.isEmpty else { return }
        if command == .repeatArea && lastArea == nil { message = "Capture an area first."; showSettings(); return }
        self.command = command
        switch command {
        case .fullscreen: begin(.display, command: command)
        case .anyWindow, .activeWindow: begin(.window, command: command)
        case .area, .repeatArea, .recognition, .scrolling: begin(.region, command: command)
        default: begin(nil, command: command)
        }
    }
    func begin(_ mode: CaptureMode? = nil, command: CaptureCommand = .capture) {
        guard !busy, overlays.isEmpty else { return }
        feedbackTask?.cancel()
        captureFeedbackProgress = nil
        self.command = command
        previewPanel?.close(); previewPanel = nil
        busy = true; message = nil
        let token = UUID(); session = token
        previousApp = NSWorkspace.shared.frontmostApplication
        settingsWasVisible = NSApp.windows.contains { $0.identifier?.rawValue == "settings" && $0.isVisible }
        let chosenMode = mode ?? preferences.value.defaultMode
        let pointer = NSEvent.mouseLocation
        task = Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                permissionNeeded = false; screenAccessGranted = true
                for window in NSApp.windows where window.identifier?.rawValue == "settings" { window.orderOut(nil) }
                let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                var frames: [(NSScreen, CGImage, [WindowRegion])] = []
                // All frozen images are obtained before the first overlay becomes visible.
                let screens = NSScreen.screens
                let targetScreen = screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first
                let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                for screen in screens where chosenMode != .display || screen === targetScreen {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false; config.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
                    try Task.checkCancellation()
                    let regions = windowInfo.compactMap { info -> WindowRegion? in
                        guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != ProcessInfo.processInfo.processIdentifier,
                              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                              let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary), rect.width > 20, rect.height > 20 else { return nil }
                        let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: screen.frame.size))
                        guard !local.isNull else { return nil }
                        return WindowRegion(rect: local, ownerPID: pid)
                    }
                    frames.append((screen, image, regions))
                }
                guard session == token, !frames.isEmpty else { throw FastShotError.message("No available displays. Reconnect a display and try again.") }
                if chosenMode == .display, let (screen, image, _) = frames.first {
                    let window = CaptureWindow(screen: screen, source: image, coordinator: self)
                    overlays = [window]
                    busy = false
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    if let view = window.captureView { selected(view) }
                    return
                }
                for (screen, image, regions) in frames {
                    let window = CaptureWindow(screen: screen, source: image, regions: regions, mode: chosenMode, coordinator: self)
                    overlays.append(window)
                }
                NSApp.activate()
                for window in overlays { window.makeKeyAndOrderFront(nil) }
                if let target = overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { target.makeKey() }
                // Cursor rects only apply after the pointer next moves; show the crosshair now.
                NSCursor.crosshair.set()
                busy = false
                if command == .fullscreen || command == .activeWindow || command == .repeatArea {
                    let target = command == .repeatArea
                        ? overlays.first(where: { ($0.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == lastArea?.display })
                        : (command == .activeWindow
                            ? overlays.first(where: { window in window.captureView?.regions.contains(where: { $0.ownerPID == Int(previousApp?.processIdentifier ?? -1) }) == true })
                            : overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) })) ?? overlays.first
                    guard let target, let view = target.captureView else { throw FastShotError.message("The previous display is unavailable. Select an area again.") }
                    let rect: CGRect?
                    if command == .fullscreen { rect = view.bounds }
                    else if command == .repeatArea { rect = lastArea?.rect }
                    else { rect = view.regions.first(where: { $0.ownerPID == Int(previousApp?.processIdentifier ?? -1) }).map(\.rect) }
                    guard let rect, view.bounds.contains(rect), rect.width >= 2, rect.height >= 2 else { throw FastShotError.message("No visible active window or valid previous area is available.") }
                    view.selection = rect
                    activate(target)
                    selected(view)
                }
            } catch is CancellationError { if session == token { finish(restore: true) } }
            catch {
                if session == token {
                    if Self.isPermissionError(error) { screenAccessGranted = false; permissionNeeded = true; message = Self.permissionHelp }
                    else { message = "Capture failed: \(error.localizedDescription)" }
                    finish(restore: true); showSettings()
                }
            }
        }
    }
    func activate(_ active: CaptureWindow) {
        for window in overlays where window !== active { window.orderOut(nil) }
        active.makeKeyAndOrderFront(nil)
    }
    func cancel() {
        task?.cancel(); session = UUID()
        previewPanel?.close(); previewPanel = nil
        scrollImage = nil; scrollRegion = nil
        finish(restore: true)
    }
    private func finish(restore: Bool) {
        for window in overlays { window.orderOut(nil); window.contentView = nil; window.close() }
        overlays.removeAll(); busy = false; task = nil
        if settingsWasVisible { showSettings() }
        if restore { previousApp?.activate() }
        previousApp = nil
    }
    func showSettings() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) { window.makeKeyAndOrderFront(nil) }
        else { reopenSettings?() }
    }
    /// Read current authorization without showing a system permission prompt.
    func refreshScreenPermission() {
        screenAccessGranted = permissionPreflight()
        if screenAccessGranted {
            permissionNeeded = false
            if message == Self.permissionHelp { message = nil }
        }
    }
    func requestPermission() {
        guard !busy, overlays.isEmpty else { return }
        task = Task { await checkScreenPermission() }
    }
    func checkScreenPermission() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            // This is the native capture API's request, not a preflight check.
            // Do not open Settings concurrently with its system permission prompt.
            try await permissionRequest()
            try Task.checkCancellation()
            permissionNeeded = false; screenAccessGranted = true
            message = "Screen access is ready. Choose Region, Window or Display to capture."
        } catch is CancellationError { return }
        catch {
            screenAccessGranted = false; permissionNeeded = true
            message = Self.permissionHelp
        }
    }
    private static let permissionHelp = "Allow FastShot in System Settings → Privacy & Security → Screen & System Audio Recording, then retry. If it is missing, use Reveal FastShot and add that app with the + button. Quit and reopen FastShot if macOS asks."
    private static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }
    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func export(_ view: CaptureView, action: OutputAction) {
        guard !busy, let crop = view.pixelCrop, crop.width > 0 else { return }
        if !view.isEditor, view.mode == .region, let rect = view.selection,
           let display = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            lastArea = (display, rect)
        }
        busy = true
        do {
            if action == .ocr {
                let mode: TextRecognition.Mode = NSEvent.modifierFlags.contains(.option) ? .accurate : .fast
                let image = try Renderer.recognitionImage(source: view.source, crop: crop, items: view.history.items)
                let instant = command == .recognition
                let token = session
                view.showMessage(mode == .fast ? "Recognising text…" : "Recognising text with full language support…")
                task = Task {
                    do {
                        let text = try await (instant ? TextRecognition.recognizeContent(image, mode: mode) : TextRecognition.recognize(image, mode: mode))
                        guard !Task.isCancelled, session == token else { return }
                        if text.isEmpty { view.showMessage("No text or QR code found. Try a larger or clearer selection."); busy = false; return }
                        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
                        guard pasteboard.setString(text, forType: .string) else { throw FastShotError.message("Could not copy text to the clipboard.") }
                        let lines = text.split(whereSeparator: \.isNewline).count
                        confirmCapture()
                        finish(restore: true); message = "Text copied."
                        Toast.show(lines == 1 ? "Copied 1 line of text" : "Copied \(lines) lines of text", symbol: "text.viewfinder")
                    } catch { if session == token { busy = false; view.showMessage(error.localizedDescription) } }
                }
                return
            }
            let image = try Renderer.render(source: view.source, crop: crop, items: view.history.items)
            if action == .copy {
                let data = try Renderer.encode(image, format: "png")
                let pb = NSPasteboard.general; pb.clearContents()
                guard pb.setData(data, forType: .png) else { throw FastShotError.message("Could not copy the image. Try again.") }
                finish(restore: true); message = "Screenshot copied."
                Toast.show("Screenshot copied", symbol: "doc.on.clipboard")
                return
            }
            if action == .pin {
                // Read the on-screen position before the overlay closes; the editor has none worth keeping.
                let anchor = view.isEditor ? nil : view.selectionOnScreen
                finish(restore: true); message = "Screenshot pinned."
                pin(image, over: anchor)
                return
            }
            let prefs = preferences.value
            var format = prefs.format
            var url: URL
            if action == .save {
                let panel = NSSavePanel()
                panel.title = "Save Screenshot"; panel.prompt = "Save"
                panel.allowedContentTypes = [format == "jpeg" ? .jpeg : .png]; panel.allowsOtherFileTypes = false; panel.canCreateDirectories = true
                let directory = try preferences.saveDirectory()
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                panel.directoryURL = directory
                let picker = SaveFormatPicker(frame: CGRect(x: 0, y: 0, width: 180, height: 28))
                picker.panel = panel; picker.target = picker; picker.action = #selector(SaveFormatPicker.changed)
                picker.addItems(withTitles: ["PNG", "JPEG"]); picker.selectItem(at: format == "jpeg" ? 1 : 0)
                panel.accessoryView = picker
                panel.nameFieldStringValue = try Filename.render(prefs.filenameTemplate, width: image.width, height: image.height) + (format == "jpeg" ? ".jpg" : ".png")
                // The save panel is hosted out of process and ignores window levels, so it would open
                // invisibly behind the screen-saver-level overlay. Step the overlay aside while it is up.
                for window in overlays { window.orderOut(nil) }
                NSApp.activate()
                guard panel.runModal() == .OK, let destination = panel.url else {
                    busy = false
                    if let window = view.window, overlays.contains(where: { $0 === window }) { NSApp.activate(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view) }
                    return
                }
                format = picker.indexOfSelectedItem == 1 ? "jpeg" : "png"
                url = destination
            } else {
                let directory = try preferences.saveDirectory()
                let access = directory.startAccessingSecurityScopedResource(); defer { if access { directory.stopAccessingSecurityScopedResource() } }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try Renderer.encode(image, format: format, quality: prefs.jpegQuality)
                let saved = try OutputFiles.quickSave(data, directory: directory, template: prefs.filenameTemplate, width: image.width, height: image.height, format: format)
                finish(restore: true); message = "Saved to \(saved.path)"
                Toast.show("Saved \(saved.lastPathComponent)", symbol: "checkmark.circle"); return
            }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Renderer.encode(image, format: format, quality: prefs.jpegQuality).write(to: url, options: .atomic)
            finish(restore: true); message = "Saved to \(url.path)"
            Toast.show("Saved \(url.lastPathComponent)", symbol: "checkmark.circle")
        } catch {
            busy = false
            if let window = view.window, !window.isVisible, overlays.contains(where: { $0 === window }) { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
            view.showMessage(error.localizedDescription)
        }
    }
}

nonisolated enum OutputAction { case copy, save, quickSave, ocr, pin }
nonisolated struct WindowRegion { let rect: CGRect; var ownerPID: Int = 0 }

/// Run Vision outside the main actor; only sanitized pixels cross this boundary.
nonisolated enum TextRecognition {
    enum Mode { case fast, accurate }

    /// A single native pass: never silently load the slower multilingual model.
    @concurrent static func recognize(_ image: CGImage, mode: Mode = .fast) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = mode == .fast ? .fast : .accurate
        request.usesLanguageCorrection = mode == .accurate
        request.automaticallyDetectsLanguage = mode == .accurate
        let input = mode == .fast ? try boundedImage(image) : image
        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
        try Task.checkCancellation()
        let observations = request.results ?? []
        let words = observations.compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
        // Group observations that share a baseline into one line, top to bottom (Vision's origin is bottom-left).
        var lines: [[(box: CGRect, text: String)]] = []
        for word in words.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = lines.last?.first, abs(anchor.box.midY - word.box.midY) < min(anchor.box.height, word.box.height) / 2 { lines[lines.count - 1].append(word) }
            else { lines.append([word]) }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    @concurrent static func recognizeContent(_ image: CGImage, mode: Mode = .fast) async throws -> String {
        let text = try await recognize(image, mode: mode)
        try Task.checkCancellation()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        var parts = text.isEmpty ? [] : [text]
        for observation in request.results ?? [] {
            if let payload = observation.payloadStringValue, !parts.contains(where: { $0.contains(payload) }) { parts.append(payload) }
        }
        return parts.joined(separator: "\n")
    }

    /// Bound work for large Retina displays without resizing ordinary selections.
    static func boundedImage(_ image: CGImage) throws -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let scale = min(1, 4096 / max(width, height), sqrt(8_000_000 / (width * height)))
        guard scale < 1 else { return image }
        let size = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FastShotError.message("The selection is too large to recognize. Try a smaller area.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw FastShotError.message("Could not prepare text recognition.") }
        return result
    }

}
final class SaveFormatPicker: NSPopUpButton {
    weak var panel: NSSavePanel?
    @objc func changed() {
        let jpeg = indexOfSelectedItem == 1
        panel?.allowedContentTypes = [jpeg ? .jpeg : .png]
        if let name = panel?.nameFieldStringValue {
            panel?.nameFieldStringValue = (name as NSString).deletingPathExtension + (jpeg ? ".jpg" : ".png")
        }
    }
}

extension CaptureCoordinator {
    private func confirmCapture() {
        feedbackTask?.cancel()
        captureFeedbackProgress = 0
        feedbackTask = Task { [weak self] in
            for frame in 1...18 {
                do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
                guard let self else { return }
                captureFeedbackProgress = Double(frame) / 18
            }
            self?.captureFeedbackProgress = nil
        }
    }

    func selected(_ view: CaptureView) {
        // Switching an existing capture overlay to Display also needs no confirmation click.
        if view.mode == .display, !view.isEditor, let screen = view.window?.screen {
            let image = view.source
            for window in overlays { window.orderOut(nil); window.contentView = nil; window.close() }
            let editor = CaptureWindow(screen: screen, source: image, coordinator: self)
            overlays = [editor]
            editor.makeKeyAndOrderFront(nil)
            if let canvas = editor.captureView { selected(canvas) }
            return
        }
        guard let crop = view.pixelCrop, let selection = view.selection else { return }
        if view.mode == .region, let display = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            lastArea = (display, selection)
            if command == .scrolling { scrollRegion = (display, crop) }
        }
        if command == .recognition { export(view, action: .ocr); return }
        do {
            let image = try Renderer.render(source: view.source, crop: crop, items: view.history.items)
            if command == .scrolling {
                scrollImage = image
                confirmCapture()
                finish(restore: true)
                showScrollControls(image)
                return
            }
            let prefs = preferences.value
            if prefs.copyAfterCapture { try copyImage(image) }
            if prefs.saveAfterCapture { try saveImage(image) }
            confirmCapture()
            guard prefs.showAfterCapture else { finish(restore: true); return }
            if view.isEditor { return }
            if view.mode == .region && prefs.areaDestination == .editor && command != .fullscreen && command != .activeWindow { return }
            let anchor = view.selectionOnScreen
            finish(restore: true)
            showPreview(image, over: anchor)
        } catch { view.showMessage(error.localizedDescription) }
    }

    private func copyImage(_ image: CGImage) throws {
        let data = try Renderer.encode(image, format: "png")
        let pb = NSPasteboard.general; pb.clearContents()
        guard pb.setData(data, forType: .png) else { throw FastShotError.message("Could not copy image.") }
    }
    @discardableResult private func saveImage(_ image: CGImage) throws -> URL {
        let directory = try preferences.saveDirectory()
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefs = preferences.value
        let url = try OutputFiles.quickSave(Renderer.encode(image, format: prefs.format, quality: prefs.jpegQuality), directory: directory, template: prefs.filenameTemplate, width: image.width, height: image.height, format: prefs.format)
        message = "Saved to \(url.path)"
        return url
    }
    private func showPreview(_ image: CGImage, over anchor: CGRect? = nil) {
        previewPanel?.close()
        let panel = CapturePreview(image: image)
        panel.addButton("Edit") { [weak self] in self?.openEditor(image) }
        panel.addButton("Pin") { [weak self] in
            guard let self else { return }
            previewPanel?.close(); previewPanel = nil
            pin(image, over: anchor)
        }
        panel.addButton("Copy") { [weak self, weak panel] in
            guard let self else { return }
            do { try copyImage(image); panel?.showStatus("Copied to clipboard") }
            catch { panel?.showError(error.localizedDescription) }
        }
        panel.addButton("Quick Save") { [weak self, weak panel] in
            guard let self else { return }
            do { try saveImage(image); panel?.showStatus(message ?? "Screenshot saved") }
            catch { panel?.showError(error.localizedDescription) }
        }
        panel.present(timeout: preferences.value.thumbnailDismissal.seconds)
        previewPanel = panel
    }
    private func previewAction(_ action: () throws -> Void) {
        do { try action() }
        catch { message = error.localizedDescription; showSettings() }
    }
    @discardableResult private func openEditor(_ image: CGImage) -> Bool {
        guard overlays.isEmpty, !busy, let screen = NSScreen.main else { return false }
        previewPanel?.close(); previewPanel = nil
        session = UUID(); command = .capture
        previousApp = NSWorkspace.shared.frontmostApplication
        let window = CaptureWindow(screen: screen, source: image, coordinator: self)
        overlays = [window]
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        return true
    }
    /// Float a finished screenshot above other apps, over the area it came from when known.
    func pin(_ image: CGImage, over anchor: CGRect? = nil) {
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let actual = PinLayout.actualSize(pixelSize: CGSize(width: image.width, height: image.height), scale: screen?.backingScaleFactor ?? 2)
        let frame = PinLayout.frame(actualSize: actual, visible: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900), over: anchor)
        let window = PinnedImageWindow(image: image, frame: frame, actualSize: actual)
        window.onCopy = { [weak self] in
            guard let self else { return }
            do { try copyImage(image); Toast.show("Screenshot copied", symbol: "doc.on.clipboard") }
            catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
        }
        window.onSave = { [weak self] in
            guard let self else { return }
            do { Toast.show("Saved \(try saveImage(image).lastPathComponent)", symbol: "checkmark.circle") }
            catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
        }
        window.onEdit = { [weak self, weak window] in
            if self?.openEditor(image) == true { window?.close() }
        }
        window.onCloseAll = { [weak self] in self?.closeAllPins() }
        window.onClose = { [weak self, weak window] in self?.pins.removeAll { $0 === window } }
        pins.append(window)
        window.orderFrontRegardless()
        Toast.show("Pinned · scroll to zoom, double-click to close", symbol: "pin.fill")
    }
    func closeAllPins() { for pin in pins { pin.close() } }
    private func showScrollControls(_ image: CGImage) {
        previewPanel?.close()
        let panel = CapturePreview(image: image, instruction: "Scroll down, leaving at least ¼ of the previous frame visible, then Add Frame.")
        panel.addButton("Add Frame") { [weak self] in self?.addScrollFrame() }
        panel.addButton("Finish") { [weak self] in
            guard let self, let image = scrollImage else { return }
            scrollImage = nil; scrollRegion = nil
            previewAction {
                if preferences.value.copyAfterCapture { try copyImage(image) }
                if preferences.value.saveAfterCapture { try saveImage(image) }
            }
            if preferences.value.showAfterCapture { showPreview(image) } else { previewPanel?.close(); previewPanel = nil }
        }
        panel.onClose = { [weak self] in
            guard let self else { return }
            task?.cancel(); session = UUID(); busy = false
            scrollImage = nil; scrollRegion = nil; previewPanel = nil
        }
        panel.present(); previewPanel = panel
    }
    private func addScrollFrame() {
        guard !busy, let region = scrollRegion, let previous = scrollImage else { return }
        busy = true
        let token = session
        previewPanel?.orderOut(nil)
        task = Task {
            defer { busy = false; if session == token { previewPanel?.orderFrontRegardless() } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == region.display }) else { throw FastShotError.message("Display disconnected.") }
                let config = SCStreamConfiguration()
                config.width = Int(display.width); config.height = Int(display.height)
                if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == region.display }) {
                    config.width = Int(screen.frame.width * screen.backingScaleFactor); config.height = Int(screen.frame.height * screen.backingScaleFactor)
                }
                config.showsCursor = false; config.captureResolution = .best
                let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                let frame = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
                try Task.checkCancellation()
                guard session == token, scrollRegion != nil else { return }
                guard let crop = frame.cropping(to: region.crop) else { throw FastShotError.message("The selected area is no longer available.") }
                let stitched = try await ScrollStitcher.append(previous, crop)
                guard !Task.isCancelled, session == token, scrollRegion != nil else { return }
                scrollImage = stitched
                confirmCapture()
                previewPanel?.updateImage(stitched)
            } catch { previewPanel?.showError(error.localizedDescription) }
        }
    }
}
