import Testing
import AppKit
import SwiftUI
import ImageIO
@testable import FastShot

struct GeometryTests {
    @Test func reverseDragAndMixedScale() {
        let rect = Geometry.rect(CGPoint(x: 81, y: 62), CGPoint(x: 11, y: 12))
        #expect(rect == CGRect(x: 11, y: 12, width: 70, height: 50))
        let crop = Geometry.pixelCrop(rect, viewSize: CGSize(width: 100, height: 100), imageSize: CGSize(width: 200, height: 150))
        #expect(crop == CGRect(x: 22, y: 18, width: 140, height: 75))
    }
    @Test func cropClipsToImage() {
        #expect(Geometry.pixelCrop(CGRect(x: -10, y: -20, width: 200, height: 200), viewSize: CGSize(width: 100, height: 100), imageSize: CGSize(width: 200, height: 200)) == CGRect(x: 0, y: 0, width: 200, height: 200))
    }
    @Test func movesAllPoints() {
        let original = Annotation(tool: .pen, points: [CGPoint(x: 2, y: 4), CGPoint(x: 8, y: 10)], color: "#000000")
        let moved = original.moved(by: CGPoint(x: -2, y: 3))
        #expect(moved.points == [CGPoint(x: 0, y: 7), CGPoint(x: 6, y: 13)])
        #expect(moved.id == original.id)
        #expect(original.points.first == CGPoint(x: 2, y: 4))
    }
}
struct FilenameTests {
    @Test(arguments: ["../secret", "bad/name", "{unknown}", "", "a:b", "{date", "bad\nname", "bad\\name"])
    func rejectsUnsafeNames(_ name: String) {
        #expect(throws: FastShotError.self) { try Filename.render(name, width: 10, height: 20) }
    }
    @Test func allTokens() throws {
        let name = try Filename.render("{date}-{time}-{n}-{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}-{width}x{height}", width: 300, height: 400, number: 7, date: Date(timeIntervalSince1970: 0))
        #expect(!name.contains("{")); #expect(name.contains("-7-1970-")); #expect(name.hasSuffix("-300x400"))
        #expect(try Filename.render("Screenshot-{n}", width: 10, height: 10, number: 3) == "Screenshot-3")
    }
}
@MainActor struct HistoryTests {
    @Test func undoRedoAndBranching() {
        let history = EditHistory()
        let item = Annotation(tool: .rect, points: [.zero, CGPoint(x: 10, y: 10)], color: "#ffffff")
        history.commit([item]); history.commit([item.moved(by: CGPoint(x: 3, y: 0))])
        history.undo(); #expect(history.items == [item]); #expect(history.canRedo)
        history.redo(); #expect(history.items[0].points[0].x == 3)
        history.undo(); history.commit([]); #expect(!history.canRedo)
        history.undo(); #expect(history.items == [item])
    }
}
@MainActor struct RendererTests {
    func fixture() throws -> CGImage {
        // Distinct horizontal bands and a checkerboard "secret" expose upside-down or misplaced output.
        let context = try #require(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 60, width: 100, height: 20))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 20))
        for x in stride(from: 20, to: 60, by: 4) {
            context.setFillColor(x % 8 == 0 ? NSColor.white.cgColor : NSColor.black.cgColor)
            context.fill(CGRect(x: x, y: 20, width: 4, height: 40))
        }
        return try #require(context.makeImage())
    }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> NSColor {
        try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
    @Test func preservesOrientationAndNativeCrop() throws {
        let source = try fixture()
        let image = try Renderer.render(source: source, crop: CGRect(x: 0, y: 0, width: 100, height: 80), items: [])
        #expect(try pixel(image, 5, 5).redComponent > 0.95)
        #expect(try pixel(image, 5, 75).blueComponent > 0.95)
        let cropped = try Renderer.render(source: source, crop: CGRect(x: 10, y: 2, width: 30, height: 12), items: [])
        #expect(cropped.width == 30); #expect(cropped.height == 12)
        #expect(try pixel(cropped, 0, 0).redComponent > 0.95)
    }
    @Test func redactionLastAndLosslessRoundtrip() throws {
        let source = try fixture()
        let redact = Annotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: "#000000")
        let line = Annotation(tool: .line, points: [CGPoint(x: 0, y: 40), CGPoint(x: 99, y: 40)], color: "#ffffff", width: 10)
        let blur = Annotation(tool: .blur, points: [.zero, CGPoint(x: 100, y: 80)], color: "#ffffff")
        let image = try Renderer.render(source: source, crop: CGRect(x: 0, y: 0, width: 100, height: 80), items: [redact, line, blur])
        let data = try Renderer.encode(image, format: "png")
        let decodedSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(decodedSource) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        for y in 20..<60 {
            for x in 20..<60 {
                let p = try pixel(decoded, x, y)
                #expect(p.redComponent == 0 && p.greenComponent == 0 && p.blueComponent == 0 && p.alphaComponent == 1)
            }
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(decodedSource, 0, nil) as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        #expect(Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]))
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
    }
    @Test(arguments: ["png", "jpeg"])
    func formatsDecodeAtNativeDimensions(_ format: String) throws {
        let image = try Renderer.render(source: fixture(), crop: CGRect(x: 5, y: 5, width: 40, height: 30), items: [])
        let data = try Renderer.encode(image, format: format, quality: 90)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 40 && decoded.height == 30)
    }
    @Test func emptyCropFails() throws {
        let source = try fixture()
        #expect(throws: FastShotError.self) { try Renderer.render(source: source, crop: .zero, items: []) }
    }
    @Test func effectsChangePixelsAndKeepOutsideUntouched() throws {
        let source = try fixture()
        for tool in [Tool.blur, .pixelate] {
            let item = Annotation(tool: tool, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: "#000000")
            let image = try Renderer.render(source: source, crop: CGRect(x: 0, y: 0, width: 100, height: 80), items: [item])
            #expect(try pixel(image, 5, 5).redComponent > 0.95)
            let before = try pixel(source, 30, 40), after = try pixel(image, 30, 40)
            #expect(abs(before.redComponent - after.redComponent) > 0.05)
        }
    }
}

@MainActor struct NativeViewTests {
    @Test func settingsAndOverlayRenderWithoutScreenPermission() throws {
        let defaults = try #require(UserDefaults(suiteName: "FastShot.ViewTests"))
        defaults.removePersistentDomain(forName: "FastShot.ViewTests")
        defer { defaults.removePersistentDomain(forName: "FastShot.ViewTests") }
        let store = PreferencesStore(defaults: defaults)
        store.value.onboardingComplete = true
        let model = AppModel(preferences: store)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ContentView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 940, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 940)
        if let directory = ProcessInfo.processInfo.environment["FASTSHOT_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
            let fixture = try #require(bitmap.cgImage)
            let overlay = CaptureView(frame: host.frame, source: fixture, regions: [], mode: .region, coordinator: model.capture)
            window.contentView = overlay
            overlay.selection = CGRect(x: 120, y: 140, width: 600, height: 420)
            overlay.layoutSubtreeIfNeeded()
            let rep = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overlay.png"))
        }
        window.contentView = nil
    }
    @Test func visionReceivesSanitizedPixels() async throws {
        let context = try #require(CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        let redact = Annotation(tool: .redact, points: [.zero, CGPoint(x: 400, y: 100)], color: "#000000")
        let safe = try Renderer.render(source: #require(context.makeImage()), crop: CGRect(x: 0, y: 0, width: 400, height: 100), items: [redact])
        #expect(try await TextRecognition.recognize(safe).isEmpty)
    }
}

struct FileOutputTests {
    @Test(arguments: ["Screenshot", "Screenshot-{n}"])
    func quickSaveNeverOverwrites(_ template: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try OutputFiles.quickSave(Data([1, 2]), directory: directory, template: template, width: 10, height: 20, format: "png")
        let second = try OutputFiles.quickSave(Data([3, 4]), directory: directory, template: template, width: 10, height: 20, format: "png")
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data([1, 2]))
        #expect(try Data(contentsOf: second) == Data([3, 4]))
    }
}

@MainActor struct OverlayInteractionTests {
    @Test func selectDrawMoveUndoRedoAndDelete() throws {
        let defaults = try #require(UserDefaults(suiteName: "FastShot.InteractionTests"))
        defaults.removePersistentDomain(forName: "FastShot.InteractionTests")
        defer { defaults.removePersistentDomain(forName: "FastShot.InteractionTests") }
        let model = AppModel(preferences: PreferencesStore(defaults: defaults))
        let source = try RendererTests().fixture()
        _ = NSApplication.shared
        let view = CaptureView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), source: source, regions: [], mode: .region, coordinator: model.capture)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 80 - y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func drag(_ a: CGPoint, _ b: CGPoint) throws {
            view.mouseDown(with: try mouse(.leftMouseDown, a.x, a.y))
            view.mouseDragged(with: try mouse(.leftMouseDragged, b.x, b.y))
            view.mouseUp(with: try mouse(.leftMouseUp, b.x, b.y))
        }
        func key(_ text: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }
        try drag(CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 70))
        #expect(view.pixelCrop == CGRect(x: 10, y: 10, width: 80, height: 60))
        try key("x", 7)
        try drag(CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 40))
        #expect(view.history.items.count == 1)
        #expect(view.history.items.first?.bounds == CGRect(x: 10, y: 10, width: 20, height: 20))
        let image = try Renderer.render(source: source, crop: #require(view.pixelCrop), items: view.history.items)
        #expect(try RendererTests().pixel(image, 15, 15).redComponent == 0)
        try key("v", 9)
        try drag(CGPoint(x: 25, y: 25), CGPoint(x: 35, y: 35))
        #expect(view.history.items.first?.bounds.minX == 20)
        try key("z", 6, flags: .command)
        #expect(view.history.items.first?.bounds.minX == 10)
        try key("z", 6, flags: [.command, .shift])
        #expect(view.history.items.first?.bounds.minX == 20)
        try drag(CGPoint(x: 35, y: 35), CGPoint(x: 35, y: 35))
        try key("", 51)
        #expect(view.history.items.isEmpty)
        window.contentView = nil
    }
}

@MainActor struct ScreenPermissionTests {
    private func store() throws -> PreferencesStore {
        PreferencesStore(defaults: try #require(UserDefaults(suiteName: "FastShot.PermissionTests")))
    }
    @Test func nativeRequestRunsAndDenialCanBeRetried() async throws {
        var requests = 0
        let coordinator = CaptureCoordinator(preferences: try store(), permissionRequest: {
            requests += 1
            if requests == 1 { throw FastShotError.message("Screen access denied") }
        })
        #expect(requests == 0)
        await coordinator.checkScreenPermission()
        #expect(requests == 1)
        #expect(coordinator.permissionNeeded)
        #expect(coordinator.message?.contains("Reveal FastShot") == true)
        #expect(!coordinator.busy)
        await coordinator.checkScreenPermission()
        #expect(requests == 2)
        #expect(!coordinator.permissionNeeded)
        #expect(coordinator.message?.contains("ready") == true)
        #expect(!coordinator.busy)
    }
    @Test func busyRequestDoesNotPromptAgain() async throws {
        var requests = 0
        let coordinator = CaptureCoordinator(preferences: try store(), permissionRequest: { requests += 1 })
        coordinator.busy = true
        await coordinator.checkScreenPermission()
        #expect(requests == 0)
        #expect(coordinator.busy)
    }
}
