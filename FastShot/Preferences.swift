import AppKit
import Observation
import Carbon
import ServiceManagement

nonisolated struct Preferences: Codable {
    var shortcutKey: UInt32 = 25 // ANSI 9
    var shortcutModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    var shortcutLabel = "⌘ ⇧ 9"
    var defaultMode: CaptureMode = .region
    var showCaptureModePanel = true
    var format = "png"
    var jpegQuality = 90.0
    var directoryBookmark: Data?
    var directoryPath: String?
    var filenameTemplate = "Screenshot-{date}-{time}"
    var theme = "system"
    var annotationColor = "#e11d48"
    var strokeWidth = 3.0
    var fontSize = 24.0
    var redactColor = "#000000"
    var keepRunning = true
    var onboardingComplete = false
    var showMagnifier = true
    var autoSelectWindow = true
    var showAfterCapture = true
    var copyAfterCapture = false
    var saveAfterCapture = false
    var areaDestination = AreaDestination.editor
    var thumbnailDismissal = ThumbnailDismissal.manual
    var shortcuts: [String: ShortcutBinding] = [:]

    init() {}
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortcutKey = try c.decodeIfPresent(UInt32.self, forKey: .shortcutKey) ?? 25
        shortcutModifiers = try c.decodeIfPresent(UInt32.self, forKey: .shortcutModifiers) ?? UInt32(cmdKey | shiftKey)
        shortcutLabel = try c.decodeIfPresent(String.self, forKey: .shortcutLabel) ?? "⌘ ⇧ 9"
        defaultMode = try c.decodeIfPresent(CaptureMode.self, forKey: .defaultMode) ?? .region
        showCaptureModePanel = try c.decodeIfPresent(Bool.self, forKey: .showCaptureModePanel) ?? true
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "png"
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 90
        filenameTemplate = try c.decodeIfPresent(String.self, forKey: .filenameTemplate) ?? "Screenshot-{date}-{time}"
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        annotationColor = try c.decodeIfPresent(String.self, forKey: .annotationColor) ?? "#e11d48"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 3
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 24
        redactColor = try c.decodeIfPresent(String.self, forKey: .redactColor) ?? "#000000"
        keepRunning = try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? true
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        showMagnifier = try c.decodeIfPresent(Bool.self, forKey: .showMagnifier) ?? true
        autoSelectWindow = try c.decodeIfPresent(Bool.self, forKey: .autoSelectWindow) ?? true
        showAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .showAfterCapture) ?? true
        copyAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .copyAfterCapture) ?? false
        saveAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .saveAfterCapture) ?? false
        areaDestination = try c.decodeIfPresent(AreaDestination.self, forKey: .areaDestination) ?? .editor
        thumbnailDismissal = try c.decodeIfPresent(ThumbnailDismissal.self, forKey: .thumbnailDismissal) ?? .manual
        shortcuts = try c.decodeIfPresent([String: ShortcutBinding].self, forKey: .shortcuts) ?? [:]
        directoryBookmark = try c.decodeIfPresent(Data.self, forKey: .directoryBookmark)
        directoryPath = try c.decodeIfPresent(String.self, forKey: .directoryPath)
    }

    func menuBinding(for mode: CaptureMode) -> ShortcutBinding? {
        let action: CaptureCommand = switch mode {
        case .region: .area
        case .window: .anyWindow
        case .display: .fullscreen
        }
        // The default capture shortcut opens this mode unless it has a dedicated binding.
        return binding(for: action) ?? (mode == defaultMode ? binding(for: .capture) : nil)
    }

    func binding(for action: CaptureCommand) -> ShortcutBinding? {
        if let stored = shortcuts[action.rawValue] { return stored.key == nil ? nil : stored }
        return action == .capture ? ShortcutBinding(key: shortcutKey, modifiers: shortcutModifiers, label: shortcutLabel) : nil
    }

    var captureShortcutLabel: String {
        binding(for: .capture)?.label ?? "No shortcut assigned"
    }
}

@Observable final class PreferencesStore {
    var value: Preferences { didSet { persist(); applyAppearance() } }
    private let defaults: UserDefaults
    var error: String?
    private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "FastShot.preferences"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) { value = saved }
        else { value = Preferences() }
        applyAppearance()
    }
    private func persist() {
        do { defaults.set(try JSONEncoder().encode(value), forKey: "FastShot.preferences") }
        catch { self.error = "Could not save preferences: \(error.localizedDescription)" }
    }
    func applyAppearance() {
        NSApp?.appearance = switch value.theme { case "light": NSAppearance(named: .aqua); case "dark": NSAppearance(named: .darkAqua); default: nil }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            value.directoryBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            value.directoryPath = url.path
        } catch { self.error = error.localizedDescription }
    }
    func saveDirectory() throws -> URL {
        if let bookmark = value.directoryBookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                value.directoryBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return url
        }
        return try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FastShot", isDirectory: true)
    }
    var launchAtLogin: Bool { loginEnabled }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { self.error = "Enable FastShot in System Settings → General → Login Items to finish enabling launch at login." }
        }
        catch { self.error = "Could not change launch at login: \(error.localizedDescription)" }
    }
}

nonisolated enum Filename {
    static func render(_ template: String, width: Int, height: Int, number: Int = 1, date: Date = .now) throws -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        func part(_ format: String) -> String { formatter.dateFormat = format; return formatter.string(from: date) }
        let values = ["date": part("yyyy-MM-dd"), "time": part("HHmmss"), "n": String(number), "YYYY": part("yyyy"), "MM": part("MM"), "DD": part("dd"), "hh": part("HH"), "mm": part("mm"), "ss": part("ss"), "width": String(width), "height": String(height)]
        var result = template.trimmingCharacters(in: .whitespacesAndNewlines)
        for (key, value) in values { result = result.replacingOccurrences(of: "{\(key)}", with: value) }
        guard !result.isEmpty, result.utf8.count <= 180, !result.contains(".."), !result.contains(where: { "/\\:{}".contains($0) || $0.isNewline || $0.asciiValue.map({ $0 < 32 }) == true }) else {
            throw FastShotError.message("Use a file name with supported tokens, without slashes, colons, or unknown {tokens}.")
        }
        return result
    }
}

nonisolated enum FastShotError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

nonisolated enum OutputFiles {
    static func quickSave(_ data: Data, directory: URL, template: String, width: Int, height: Int, format: String) throws -> URL {
        for number in 1...10000 {
            let name = try Filename.render(template, width: width, height: height, number: number)
            let suffix = number > 1 && !template.contains("{n}") ? "-\(number)" : ""
            let url = directory.appendingPathComponent(name + suffix).appendingPathExtension(format == "jpeg" ? "jpg" : "png")
            do { try data.write(to: url, options: .withoutOverwriting); return url }
            catch CocoaError.fileWriteFileExists { continue }
        }
        throw FastShotError.message("Too many files with this name. Change the filename template.")
    }
}
