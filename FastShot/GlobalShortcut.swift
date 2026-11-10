import AppKit
import Carbon
import SwiftUI

nonisolated enum CaptureCommand: String, Codable, CaseIterable, Identifiable {
    case capture, fullscreen, area, repeatArea, anyWindow, activeWindow, scrolling, showApp, recognition
    var id: String { rawValue }
    var title: String {
        switch self {
        case .capture: "Default capture"
        case .fullscreen: "Fullscreen screenshot"
        case .area: "Area screenshot"
        case .repeatArea: "Repeat area screenshot"
        case .anyWindow: "Any window screenshot"
        case .activeWindow: "Active window screenshot"
        case .scrolling: "Scrolling screenshot"
        case .showApp: "Show FastShot"
        case .recognition: "Instant Text/QR Recognition"
        }
    }
}
nonisolated struct ShortcutBinding: Codable, Equatable {
    var key: UInt32?
    var modifiers: UInt32 = 0
    var label: String = "Record Shortcut"
}
extension ShortcutBinding {
    var menuShortcut: KeyboardShortcut? {
        guard let key, key <= UInt16.max,
              let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true) else { return nil }
        event.flags = []
        guard let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased().first else { return nil }
        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
    }
}

nonisolated enum AreaDestination: String, Codable, CaseIterable { case thumbnail, editor }
nonisolated enum ThumbnailDismissal: String, Codable, CaseIterable {
    case manual, fiveSeconds, tenSeconds, thirtySeconds
    var seconds: Double? { switch self { case .manual: nil; case .fiveSeconds: 5; case .tenSeconds: 10; case .thirtySeconds: 30 } }
    var title: String { seconds.map { "After \(Int($0)) seconds" } ?? "Manually (close button)" }
}

final class GlobalShortcut {
    private var hotKeys: [CaptureCommand: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onCommand: ((CaptureCommand) -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x46534854, id.id > 0, id.id <= CaptureCommand.allCases.count else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onCommand?(CaptureCommand.allCases[Int(id.id) - 1]) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    isolated deinit {
        for hotKey in hotKeys.values { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func register(_ action: CaptureCommand, binding: ShortcutBinding?) throws {
        guard let binding, let key = binding.key else {
            if let old = hotKeys.removeValue(forKey: action) { UnregisterEventHotKey(old) }; return
        }
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x46534854, id: UInt32(CaptureCommand.allCases.firstIndex(of: action)! + 1))
        let status = RegisterEventHotKey(key, binding.modifiers, id, GetApplicationEventTarget(), 0, &next)
        guard status == noErr, let next else { throw FastShotError.message("That shortcut is already in use (\(status)). Choose another combination.") }
        if let old = hotKeys[action] { UnregisterEventHotKey(old) }
        hotKeys[action] = next
    }
}
