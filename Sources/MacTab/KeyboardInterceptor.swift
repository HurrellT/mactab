import AppKit
import ApplicationServices

enum SwitcherKey {
    case tab(backwards: Bool), grave(backwards: Bool), left, right, up, down, accept, cancel, release
}

final class KeyboardInterceptor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var suppressed: Set<CGKeyCode> = []
    var isSwitching: () -> Bool = { false }
    var onKey: (SwitcherKey) -> Void = { _ in }
    var onInterruption: () -> Void = {}
    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        // Recreate an invalid/disabled tap instead of treating its stored pointer as ready.
        if tap != nil { stop() }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                             callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardInterceptor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        guard isRunning else { stop(); return false }
        return true
    }

    func stop() {
        onInterruption()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        suppressed.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onInterruption()
            suppressed.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, suppressed.remove(code) != nil { return nil }
        let command = event.flags.contains(.maskCommand)
        if type == .flagsChanged {
            if isSwitching(), !command { onKey(.release) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let backwards = event.flags.contains(.maskShift)
        let plainCommand = command && !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate)
        var key: SwitcherKey?
        if code == 48, plainCommand { key = .tab(backwards: backwards) }
        else if code == 50, plainCommand { key = .grave(backwards: backwards) }
        else if isSwitching() {
            switch code {
            case 123: key = .left
            case 124: key = .right
            case 125: key = .down
            case 126: key = .up
            case 36, 76: key = .accept
            case 53: key = .cancel
            default: break
            }
        }
        guard let key else { return Unmanaged.passUnretained(event) }
        suppressed.insert(code)
        onKey(key)
        return nil
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
