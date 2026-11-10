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
        .defaultSize(width: 780, height: 580).windowResizability(.contentMinSize).windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                ForEach(CaptureMode.allCases) { mode in captureButton(mode) }
            }
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updates: model.updates) }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.capture.showSettings() }.keyboardShortcut(",") }
        }
        MenuBarExtra {
            ForEach(CaptureMode.allCases) { mode in captureButton(mode) }
            ForEach([CaptureCommand.repeatArea, .activeWindow, .scrolling, .recognition]) { command in
                Button(command.title) { model.capture.perform(command) }
                    .keyboardShortcut(model.preferences.value.binding(for: command)?.menuShortcut)
            }
            if !model.capture.pins.isEmpty {
                Divider()
                Button("Close Pinned Screenshots", systemImage: "pin.slash") { model.capture.closeAllPins() }
            }
            Divider()
            Button("Settings…") { model.capture.showSettings() }.keyboardShortcut(",")
            CheckForUpdatesButton(updates: model.updates)
            Button("Quit FastShot") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: { Image(nsImage: Brand.captureMenuBarImage(progress: model.capture.captureFeedbackProgress)).accessibilityLabel("FastShot") }
    }
    private func captureButton(_ mode: CaptureMode) -> some View {
        Button("Capture \(mode.title)", systemImage: mode.symbol) { model.capture.begin(mode) }
            .keyboardShortcut(model.preferences.value.menuBinding(for: mode)?.menuShortcut)
    }
}

@Observable final class AppModel {
    var preferences: PreferencesStore
    let capture: CaptureCoordinator
    let shortcut = GlobalShortcut()
    let updates = AppUpdates()
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

        updates.start()
        shortcut.onCommand = { [weak self] command in
            guard let self, !recordingShortcut else { return }
            capture.perform(command)
        }
        for action in CaptureCommand.allCases {
            do { try shortcut.register(action, binding: preferences.value.binding(for: action)) }
            catch { shortcutError = "\(action.title): \(error.localizedDescription)" }
        }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "AnnotationFont", withExtension: "ttf", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "AnnotationFont", withExtension: "ttf", subdirectory: "Resources") ?? Bundle.main.url(forResource: "AnnotationFont", withExtension: "ttf")
        #endif
        if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        // Explicit local setup action; normal launches never ask for screen access.
        if ProcessInfo.processInfo.arguments.contains("--request-screen-access") { capture.requestPermission() }
    }
    func updateShortcut(_ action: CaptureCommand, binding: ShortcutBinding?) {
        if let binding, CaptureCommand.allCases.contains(where: {
            $0 != action && preferences.value.binding(for: $0).map { $0.key == binding.key && $0.modifiers == binding.modifiers } == true
        }) { shortcutError = "That shortcut is assigned to another FastShot action."; return }
        if preferences.value.binding(for: action) == binding { return }
        do {
            try shortcut.register(action, binding: binding)
            preferences.value.shortcuts[action.rawValue] = binding ?? ShortcutBinding(key: nil)
            shortcutError = nil
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
    // GitHub's official mark: https://github.githubassets.com/favicons/favicon.svg
    static let githubImage: NSImage? = {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "github-mark", withExtension: "png", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "github-mark", withExtension: "png")
            ?? Bundle.main.url(forResource: "github-mark", withExtension: "png", subdirectory: "Resources")
        #endif
        return url.flatMap { NSImage(contentsOf: $0) }
    }()

    static var logoImage: NSImage {
        if let image = NSImage(named: "FastShotMark") { return image }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "logo", withExtension: "png", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "logo", withExtension: "png")
        #endif
        return url.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
    }
    // Render explicit template frames: MenuBarExtra does not reliably retain view transforms.
    static func captureMenuBarImage(progress: Double?) -> NSImage {
        guard let progress else { return menuBarImage }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                check?.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
            } else {
                // One small shutter contraction and release, without changing the menu bar layout.
                let pulse = sin(progress * .pi)
                let inset = pulse * 1.5
                menuBarImage.draw(in: NSRect(x: inset, y: inset, width: 18 - inset * 2, height: 18 - inset * 2),
                                  from: .zero, operation: .sourceOver, fraction: 1 - pulse * 0.3)
            }
            return true
        }
        image.isTemplate = true
        return image
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
