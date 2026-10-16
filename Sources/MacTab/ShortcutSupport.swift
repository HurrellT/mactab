import AppKit
import SwitcherCore

extension ShortcutModifiers {
    init(flags: CGEventFlags) {
        self = []
        if flags.contains(.maskControl) { insert(.control) }
        if flags.contains(.maskAlternate) { insert(.option) }
        if flags.contains(.maskShift) { insert(.shift) }
        if flags.contains(.maskCommand) { insert(.command) }
    }
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

extension KeyboardShortcut {
    init(event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        self.init(keyCode: event.keyCode, modifiers: ShortcutModifiers(flags: flags),
                  keyLabel: event.characters(byApplyingModifiers: [])?.uppercased() ?? "")
    }
    var displayName: String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "Esc",
            76: "Enter", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return modifiers.symbols + (special[keyCode] ?? (keyLabel.isEmpty ? "Key \(keyCode)" : keyLabel))
    }
}

/// Cancellation is read on the AX queue and changed on the main thread.
final class ActionCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
