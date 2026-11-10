import AppKit
import Carbon

final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onCapture: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onCapture?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(key: UInt32, modifiers: UInt32) throws {
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x46534854, id: 1)
        let status = RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &next)
        guard status == noErr else { throw FastShotError.message("That shortcut is already in use (\(status)). Choose another combination.") }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = next
    }
}
