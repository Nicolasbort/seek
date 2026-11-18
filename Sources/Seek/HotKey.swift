import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x5345_454B), id: 1) // 'SEEK'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Parses strings like "cmd+shift+space" into (keyCode, Carbon modifier mask).
    static func parse(_ text: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in text.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default:
                guard let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    static let keyCodes: [String: UInt32] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
