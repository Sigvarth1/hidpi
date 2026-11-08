import AppKit
import Carbon

/// Carbon registered hotkeys do not require Accessibility or keyboard monitoring permission.
final class Shortcuts {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onAction: ((Int) -> Void)?
    private(set) var status = "Disabled"

    func configure(enabled: Bool) {
        clear()
        guard enabled else { status = "Disabled"; return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotkey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
            guard status == noErr else { return status }
            let shortcuts = Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcuts.onAction?(Int(hotkey.id)) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { status = "Could not register keyboard handler (\(result))"; return }
        // Register each key independently so one conflict does not disable the rest.
        var failed: [String] = []
        for (index, key) in Self.keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x48445049, id: UInt32(index))
            let result = RegisterEventHotKey(key.code, UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { references.append(ref) } else { failed.append(key.name) }
        }
        status = Self.summary(failed: failed)
        if references.isEmpty { clear() }
    }
    /// Key codes in action order: left/right arrows, then digits 1–9.
    static let keys: [(code: UInt32, name: String)] = [(123, "←"), (124, "→"), (18, "1"), (19, "2"), (20, "3"),
                                                        (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9")]
    static func summary(failed: [String]) -> String {
        if failed.isEmpty { return "Enabled — ⌃⌥⌘ ← / → favorites; ⌃⌥⌘ 1–9 profiles" }
        if failed.count == keys.count { return "Could not register any shortcut; they may be in use by another app" }
        return "Enabled, except ⌃⌥⌘ \(failed.joined(separator: ", ")) (could not register; possibly in use by another app)"
    }
    private func clear() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    deinit { clear() }
}
