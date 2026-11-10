import Testing
import AppKit
import CoreImage
import Carbon
import SwiftUI
@testable import FastShot

struct CapturePreferenceTests {
    @Test func menuHintsFollowAssignedShortcutsAndDefaultMode() {
        var prefs = Preferences()
        #expect(prefs.menuBinding(for: .region) == prefs.binding(for: .capture))
        #expect(prefs.menuBinding(for: .window) == nil)
        prefs.defaultMode = .window
        #expect(prefs.menuBinding(for: .region) == nil)
        #expect(prefs.menuBinding(for: .window) == prefs.binding(for: .capture))
        let dedicated = ShortcutBinding(key: 18, modifiers: UInt32(cmdKey | optionKey), label: "⌥ ⌘ 1")
        prefs.shortcuts[CaptureCommand.anyWindow.rawValue] = dedicated
        #expect(prefs.menuBinding(for: .window) == dedicated)
        prefs.shortcuts[CaptureCommand.capture.rawValue] = ShortcutBinding(key: 17, modifiers: UInt32(cmdKey), label: "⌘ T")
        #expect(prefs.captureShortcutLabel == "⌘ T")
        prefs.shortcuts[CaptureCommand.capture.rawValue] = ShortcutBinding(key: nil)
        prefs.shortcuts[CaptureCommand.anyWindow.rawValue] = ShortcutBinding(key: nil)
        #expect(prefs.menuBinding(for: .window) == nil)
        #expect(prefs.captureShortcutLabel == "No shortcut assigned")
    }

    @MainActor @Test func menuShortcutUsesKeyCodeAndAllModifiers() throws {
        let binding = ShortcutBinding(key: 25, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), label: "Custom")
        let shortcut = try #require(binding.menuShortcut)
        #expect(shortcut.key == KeyEquivalent("9"))
        #expect(shortcut.modifiers == [.command, .shift, .option, .control])
        #expect(ShortcutBinding(key: nil).menuShortcut == nil)
    }

    @Test func migratesExistingPreferencesAndRoundTripsNewOptions() throws {
        let old = Data(#"{"shortcutKey":12,"shortcutModifiers":768,"shortcutLabel":"Custom","format":"jpeg","filenameTemplate":"Keep-{n}","onboardingComplete":true}"#.utf8)
        var prefs = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(prefs.filenameTemplate == "Keep-{n}")
        #expect(prefs.onboardingComplete)
        #expect(prefs.showCaptureModePanel)
        #expect(prefs.showAfterCapture && !prefs.copyAfterCapture && !prefs.saveAfterCapture)
        #expect(prefs.binding(for: .capture)?.key == 12)
        #expect(prefs.binding(for: .area) == nil)
        prefs.showCaptureModePanel = false
        prefs.areaDestination = .thumbnail
        prefs.thumbnailDismissal = .tenSeconds
        prefs.copyAfterCapture = true
        prefs.shortcuts[CaptureCommand.capture.rawValue] = ShortcutBinding(key: nil)
        prefs.shortcuts[CaptureCommand.area.rawValue] = ShortcutBinding(key: 1, modifiers: 768, label: "Test")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(!decoded.showCaptureModePanel)
        #expect(decoded.binding(for: .capture) == nil)
        #expect(decoded.binding(for: .area)?.key == 1)
        #expect(decoded.copyAfterCapture && decoded.areaDestination == .thumbnail)
        #expect(decoded.thumbnailDismissal.seconds == 10)
        #expect(ThumbnailDismissal.manual.seconds == nil)
    }
}

@MainActor struct CaptureActionTests {
    @Test func rejectsDuplicateShortcutsWithoutChangingPreferences() throws {
        let name = "FastShot.Features.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(preferences: PreferencesStore(defaults: defaults))
        model.updateShortcut(.area, binding: model.preferences.value.binding(for: .capture))
        #expect(model.shortcutError != nil)
        #expect(model.preferences.value.binding(for: .area) == nil)
        model.updateShortcut(.capture, binding: nil)
        #expect(model.preferences.value.binding(for: .capture) == nil)
        #expect(model.shortcutError == nil)
    }
    @Test func invalidSelectionDoesNotConfirmCapture() throws {
        _ = NSApplication.shared
        let name = "FastShot.Feedback.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = CaptureCoordinator(preferences: PreferencesStore(defaults: defaults))
        let view = CaptureView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), source: try RendererTests().fixture(), regions: [], mode: .region, coordinator: coordinator)
        coordinator.selected(view)
        #expect(coordinator.captureFeedbackProgress == nil)
    }

    @Test func automaticSaveUsesCropAndPreservesExistingFiles() throws {
        _ = NSApplication.shared
        let name = "FastShot.Features.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let store = PreferencesStore(defaults: defaults)
        store.value.directoryBookmark = try directory.bookmarkData(options: .withSecurityScope)
        store.value.saveAfterCapture = true; store.value.showAfterCapture = false
        store.value.filenameTemplate = "Automatic"
        let coordinator = CaptureCoordinator(preferences: store)
        let view = CaptureView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), source: try RendererTests().fixture(), regions: [], mode: .region, coordinator: coordinator)
        view.selection = CGRect(x: 10, y: 20, width: 50, height: 30)
        #expect(coordinator.captureFeedbackProgress == nil)
        coordinator.selected(view)
        #expect(coordinator.captureFeedbackProgress != nil)
        coordinator.selected(view)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files {
            let image = try #require(NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(image.width == 50 && image.height == 30)
        }
    }
}

@MainActor struct ScrollingCaptureTests {
    @Test func stitchesOverlappingFramesWithoutReversingOrDuplicatingRows() async throws {
        let context = try #require(CGContext(data: nil, width: 80, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<240 {
            context.setFillColor(CGColor(red: CGFloat((row * 71) % 251) / 250, green: CGFloat((row * 17) % 251) / 250, blue: CGFloat((row * 131) % 251) / 250, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: 80, height: 1))
        }
        let full = try #require(context.makeImage())
        let first = try #require(full.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 120)))
        let second = try #require(full.cropping(to: CGRect(x: 0, y: 60, width: 80, height: 120)))
        let third = try #require(full.cropping(to: CGRect(x: 0, y: 120, width: 80, height: 120)))
        let firstPair = try await ScrollStitcher.append(first, second)
        let result = try await ScrollStitcher.append(firstPair, third)
        #expect(result.height == 240)
        for y in 0..<240 {
            let expected = try RendererTests().pixel(full, 40, y)
            let actual = try RendererTests().pixel(result, 40, y)
            #expect(abs(expected.redComponent - actual.redComponent) < 0.01)
        }
        await #expect(throws: FastShotError.self) { try await ScrollStitcher.append(first, first) }
    }
    @Test func readsQRPayload() async throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://fastshot.example/test".utf8), forKey: "inputMessage")
        let qr = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let image = try #require(CIContext().createCGImage(qr, from: qr.extent.insetBy(dx: -32, dy: -32)))
        #expect(try await TextRecognition.recognizeContent(image).contains("https://fastshot.example/test"))
    }
}

@MainActor struct CaptureModePanelTests {
    @Test(arguments: [true, false])
    func panelVisibilityPreservesKeyboardModeSelection(_ showPanel: Bool) throws {
        _ = NSApplication.shared
        let name = "FastShot.ModePanel.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        store.value.showCaptureModePanel = showPanel
        store.value.defaultMode = .window
        let coordinator = CaptureCoordinator(preferences: store)
        let view = CaptureView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), source: try RendererTests().fixture(), regions: [], mode: store.value.defaultMode, coordinator: coordinator)
        let panel = try #require(view.subviews.first { $0.identifier?.rawValue == "capture-mode-panel" })
        #expect(panel.isHidden == !showPanel)
        #expect(view.mode == .window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20))
        view.keyDown(with: event)
        #expect(view.mode == .display)
        #expect(panel.isHidden == !showPanel)
        view.selection = CGRect(x: 10, y: 10, width: 40, height: 30)
        #expect(panel.isHidden)
        view.selection = nil
        #expect(panel.isHidden == !showPanel)
    }
}

@MainActor struct DisplayEditorTests {
    @Test func fittingAndZoomPreserveFullResolutionAndAnnotationCoordinates() throws {
        _ = NSApplication.shared
        let name = "FastShot.DisplayEditor.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = CaptureCoordinator(preferences: PreferencesStore(defaults: defaults))
        let source = try RendererTests().fixture()
        let editor = CaptureEditorView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600), source: source, coordinator: coordinator, backingScale: 2)
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        #expect(canvas.isEditor)
        #expect(canvas.selection == canvas.bounds)
        #expect(canvas.pixelCrop == CGRect(x: 0, y: 0, width: source.width, height: source.height))
        #expect(canvas.frame.width / canvas.frame.height == CGFloat(source.width) / CGFloat(source.height))
        let annotation = Annotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: "#000000")
        canvas.history.commit([annotation])
        for scale: CGFloat in [0.25, 1, 2] {
            canvas.resizeEditorCanvas(to: CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale))
            #expect(canvas.selection == canvas.bounds)
            let crop = try #require(canvas.pixelCrop)
            #expect(crop.size == CGSize(width: source.width, height: source.height))
            #expect(canvas.history.items.first?.points == annotation.points)
            let output = try Renderer.render(source: source, crop: crop, items: canvas.history.items)
            #expect(output.width == source.width && output.height == source.height)
            #expect(try RendererTests().pixel(output, 40, 40).redComponent < 0.01)
        }
        if let directory = ProcessInfo.processInfo.environment["FASTSHOT_SNAPSHOT_DIR"] {
            editor.needsLayout = true
            editor.layoutSubtreeIfNeeded()
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("display-editor.png"))
        }
    }
}

@MainActor struct PinTests {
    @Test func layoutOpensOverCaptureOrCentredAndFitted() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let actual = PinLayout.actualSize(pixelSize: CGSize(width: 400, height: 200), scale: 2)
        #expect(actual == CGSize(width: 200, height: 100))
        let anchor = CGRect(x: 30, y: 40, width: 200, height: 100)
        #expect(PinLayout.frame(actualSize: actual, visible: visible, over: anchor) == anchor)
        #expect(PinLayout.frame(actualSize: actual, visible: visible) == CGRect(x: 400, y: 350, width: 200, height: 100))
        let large = PinLayout.frame(actualSize: CGSize(width: 4000, height: 1000), visible: visible)
        #expect(large.width == 800 && large.height == 200)
        #expect(visible.contains(large))
    }

    @Test func zoomKeepsAnchorAspectAndLimits() {
        let actual = CGSize(width: 200, height: 100)
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        let anchor = CGPoint(x: 150, y: 125)
        let doubled = PinLayout.zoomed(frame, to: 2, actualSize: actual, anchor: anchor)
        #expect(doubled.size == CGSize(width: 400, height: 200))
        #expect(abs((anchor.x - doubled.minX) / doubled.width - 0.25) < 0.0001)
        #expect(abs((anchor.y - doubled.minY) / doubled.height - 0.25) < 0.0001)
        #expect(PinLayout.zoomed(frame, to: 100, actualSize: actual, anchor: anchor).width == 1600)
        #expect(PinLayout.zoomed(frame, to: 0.001, actualSize: actual, anchor: anchor).height == 24)
    }

    @Test func pinActionFloatsRenderedCropAndClosesCleanly() throws {
        _ = NSApplication.shared
        let name = "FastShot.Pin.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = CaptureCoordinator(preferences: PreferencesStore(defaults: defaults))
        let view = CaptureView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), source: try RendererTests().fixture(), regions: [], mode: .region, coordinator: coordinator)
        view.selection = CGRect(x: 10, y: 20, width: 50, height: 30)
        view.history.commit([Annotation(tool: .redact, points: [.zero, CGPoint(x: 10, y: 10)], color: "#000000")])
        coordinator.export(view, action: .pin)
        coordinator.export(view, action: .pin)
        #expect(coordinator.pins.count == 2)
        let pin = try #require(coordinator.pins.first)
        #expect(pin.image.width == 50 && pin.image.height == 30)
        #expect(pin.level == .floating && pin.isVisible)
        // Redactions are baked into the pinned pixels, like every other output.
        #expect(try RendererTests().pixel(pin.image, 2, 2).redComponent < 0.01)
        pin.close()
        #expect(coordinator.pins.count == 1)
        coordinator.closeAllPins()
        #expect(coordinator.pins.isEmpty)
        #expect(!coordinator.busy)
    }

    @Test func pinButtonAppearsInBothOverlayBarsAndOnceInEditor() throws {
        _ = NSApplication.shared
        let name = "FastShot.PinBars.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = CaptureCoordinator(preferences: PreferencesStore(defaults: defaults))
        func pinButtons(_ stack: NSStackView) -> Int { stack.arrangedSubviews.filter { ($0 as? ToolButton)?.hint.hasPrefix("Pin to screen") == true && $0.superview != nil }.count }
        let overlay = CaptureView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), source: try RendererTests().fixture(), regions: [], mode: .region, coordinator: coordinator)
        let bars = overlay.subviews.compactMap { $0 as? NSStackView }
        #expect(bars.filter { $0.orientation == .vertical }.map(pinButtons) == [1])
        #expect(bars.filter { $0.orientation == .horizontal }.map(pinButtons).reduce(0, +) == 1)
        let editor = CaptureEditorView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600), source: try RendererTests().fixture(), coordinator: coordinator, backingScale: 2)
        let editorBars = editor.subviews.flatMap(\.subviews).compactMap { $0 as? NSStackView }
        #expect(editorBars.map(pinButtons).reduce(0, +) == 1)
    }
}
