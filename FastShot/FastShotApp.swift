import SwiftUI
import AppKit
import CoreText
import Carbon
import Darwin

@main
struct FastShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        Window("FastShot", id: "settings") {
            ContentView(model: model).background(WindowRegistration())
                .onAppear { delegate.model = model; model.start() }
        }
        .defaultSize(width: 940, height: 740).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                ForEach(CaptureMode.allCases) { mode in Button("Capture \(mode.title)") { model.capture.begin(mode) } }
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.capture.showSettings() }.keyboardShortcut(",") }
        }
        MenuBarExtra {
            ForEach(CaptureMode.allCases) { mode in Button("Capture \(mode.title)", systemImage: mode.symbol) { model.capture.begin(mode) } }
            Divider()
            Button("Settings…") { model.capture.showSettings() }.keyboardShortcut(",")
            Button("Quit FastShot") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: { Image(nsImage: Brand.menuBarImage).accessibilityLabel("FastShot") }
    }
}

@Observable final class AppModel {
    var preferences: PreferencesStore
    let capture: CaptureCoordinator
    let shortcut = GlobalShortcut()
    var shortcutError: String?
    var recordingShortcut = false
    private var started = false
    private var instanceLock: Int32 = -1
    init(preferences: PreferencesStore = PreferencesStore()) { self.preferences = preferences; capture = CaptureCoordinator(preferences: preferences) }
    func start() {
        guard !started else { return }; started = true
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("com.zerox.FastShot", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            instanceLock = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
                let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.zerox.FastShot").first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                other?.activate(); NSApp.terminate(nil); return
            }
        } catch { preferences.error = "Could not initialize FastShot: \(error.localizedDescription)" }

        shortcut.onCapture = { [weak self] in guard let self, !recordingShortcut else { return }; capture.begin() }
        do { try shortcut.register(key: preferences.value.shortcutKey, modifiers: preferences.value.shortcutModifiers) }
        catch { shortcutError = error.localizedDescription }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "AnnotationFont", withExtension: "ttf", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "AnnotationFont", withExtension: "ttf", subdirectory: "Resources") ?? Bundle.main.url(forResource: "AnnotationFont", withExtension: "ttf")
        #endif
        if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        // Explicit local setup action; normal launches never ask for screen access.
        if ProcessInfo.processInfo.arguments.contains("--request-screen-access") { capture.requestPermission() }
    }
    func updateShortcut(key: UInt32, modifiers: UInt32, label: String) {
        guard key != preferences.value.shortcutKey || modifiers != preferences.value.shortcutModifiers else { return }
        do {
            try shortcut.register(key: key, modifiers: modifiers)
            preferences.value.shortcutKey = key; preferences.value.shortcutModifiers = modifiers; preferences.value.shortcutLabel = label; shortcutError = nil
        } catch { shortcutError = error.localizedDescription }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let login = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if login {
            Task { @MainActor in
                await Task.yield()
                for window in NSApp.windows where window.identifier?.rawValue == "settings" { window.orderOut(nil) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(model?.preferences.value.keepRunning ?? true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model?.capture.showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) { model?.capture.cancel() }
}
struct WindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RegistrationView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class RegistrationView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.identifier = NSUserInterfaceItemIdentifier("settings") }
    }
}

// The reference menu-bar template preserves the original capture-and-lightning mark.
enum Brand {
    static var logoImage: NSImage {
        if let image = NSImage(named: "FastShotMark") { return image }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "logo", withExtension: "png", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "logo", withExtension: "png")
        #endif
        return url.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
    }
    static var menuBarImage: NSImage {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "tray-template", withExtension: "png", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "tray-template", withExtension: "png")
        #endif
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "FastShot")!
        image.isTemplate = true; image.size = NSSize(width: 18, height: 18)
        return image
    }
}
