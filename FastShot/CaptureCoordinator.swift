import AppKit
import Observation
import ScreenCaptureKit
import Vision
import UniformTypeIdentifiers

@Observable final class CaptureCoordinator {
    let preferences: PreferencesStore
    var busy = false
    var message: String?
    var permissionNeeded = false
    @ObservationIgnored var reopenSettings: (() -> Void)?
    private var overlays: [CaptureWindow] = []
    private var previousApp: NSRunningApplication?
    private var settingsWasVisible = false
    private var task: Task<Void, Never>?
    private var session = UUID()
    private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let permissionRequest: @MainActor () async throws -> Void

    init(preferences: PreferencesStore, permissionRequest: @escaping @MainActor () async throws -> Void = {
        _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }) {
        self.preferences = preferences
        self.permissionRequest = permissionRequest
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        })
    }
    func begin(_ mode: CaptureMode? = nil) {
        guard !busy, overlays.isEmpty else { return }
        busy = true; message = nil
        let token = UUID(); session = token
        previousApp = NSWorkspace.shared.frontmostApplication
        settingsWasVisible = NSApp.windows.contains { $0.identifier?.rawValue == "settings" && $0.isVisible }
        let chosenMode = mode ?? preferences.value.defaultMode
        task = Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                permissionNeeded = false
                for window in NSApp.windows where window.identifier?.rawValue == "settings" { window.orderOut(nil) }
                let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                var frames: [(NSScreen, CGImage, [WindowRegion])] = []
                // All frozen images are obtained before the first overlay becomes visible.
                for screen in NSScreen.screens {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false; config.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
                    try Task.checkCancellation()
                    let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    let regions = windowInfo.compactMap { info -> WindowRegion? in
                        guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != ProcessInfo.processInfo.processIdentifier,
                              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                              let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary), rect.width > 20, rect.height > 20 else { return nil }
                        let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: screen.frame.size))
                        guard !local.isNull else { return nil }
                        return WindowRegion(rect: local)
                    }
                    frames.append((screen, image, regions))
                }
                guard session == token, !frames.isEmpty else { throw FastShotError.message("No available displays. Reconnect a display and try again.") }
                for (screen, image, regions) in frames {
                    let window = CaptureWindow(screen: screen, source: image, regions: regions, mode: chosenMode, coordinator: self)
                    overlays.append(window)
                }
                NSApp.activate()
                for window in overlays { window.makeKeyAndOrderFront(nil) }
                if let target = overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { target.makeKey() }
                busy = false
            } catch is CancellationError { if session == token { finish(restore: true) } }
            catch {
                if session == token {
                    if Self.isPermissionError(error) { permissionNeeded = true; message = Self.permissionHelp }
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
    func cancel() { task?.cancel(); session = UUID(); finish(restore: true) }
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
            permissionNeeded = false
            message = "Screen access is ready. Choose Region, Window or Display to capture."
        } catch is CancellationError { return }
        catch {
            permissionNeeded = true
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
        busy = true
        do {
            let image = try Renderer.render(source: view.source, crop: crop, items: view.history.items)
            if action == .ocr {
                let token = session
                view.showMessage("Recognising text…")
                task = Task {
                    do {
                        let text = try await TextRecognition.recognize(image)
                        guard !Task.isCancelled, session == token else { return }
                        if text.isEmpty { view.showMessage("No text found. Try a larger or clearer selection."); busy = false; return }
                        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
                        guard pasteboard.setString(text, forType: .string) else { throw FastShotError.message("Could not copy text to the clipboard.") }
                        let lines = text.split(whereSeparator: \.isNewline).count
                        finish(restore: true); message = "Text copied."
                        Toast.show(lines == 1 ? "Copied 1 line of text" : "Copied \(lines) lines of text", symbol: "text.viewfinder")
                    } catch { if session == token { busy = false; view.showMessage(error.localizedDescription) } }
                }
                return
            }
            if action == .copy {
                let data = try Renderer.encode(image, format: "png")
                let pb = NSPasteboard.general; pb.clearContents()
                guard pb.setData(data, forType: .png) else { throw FastShotError.message("Could not copy the image. Try again.") }
                finish(restore: true); message = "Screenshot copied."
                Toast.show("Screenshot copied", symbol: "doc.on.clipboard")
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

nonisolated enum OutputAction { case copy, save, quickSave, ocr }
nonisolated struct WindowRegion { let rect: CGRect }

/// Run Vision outside the main actor; only sanitized pixels cross this boundary.
nonisolated enum TextRecognition {
    @concurrent static func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        let words = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
        // Group observations that share a baseline into one line, top to bottom (Vision's origin is bottom-left).
        var lines: [[(box: CGRect, text: String)]] = []
        for word in words.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = lines.last?.first, abs(anchor.box.midY - word.box.midY) < min(anchor.box.height, word.box.height) / 2 { lines[lines.count - 1].append(word) }
            else { lines.append([word]) }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
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
