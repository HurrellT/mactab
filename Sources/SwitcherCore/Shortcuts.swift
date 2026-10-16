import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 15 }
    public static let control = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
}

public struct KeyboardShortcut: Codable, Hashable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers
    public var keyLabel: String
    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyLabel: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }
    // Labels are presentation only; physical keys and modifiers determine matching.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
    public var validationError: String? {
        if modifiers.intersection([.control, .option, .command]).isEmpty {
            return "Include Command, Control, or Option in the shortcut."
        }
        if keyCode > 127 || (54...63).contains(keyCode) || keyCode == 53 {
            return "Choose a letter, number, function key, or navigation key."
        }
        if [48, 50].contains(keyCode), modifiers.contains(.command),
           modifiers.intersection([.control, .option]).isEmpty {
            return "Command-Tab and Command-` are reserved for the switcher."
        }
        return nil
    }
}

public struct ApplicationShortcutTarget: Codable, Equatable {
    public var bundleIdentifier: String
    public var bundlePath: String
    public var name: String
    public var launchIfClosed: Bool
    public init(bundleIdentifier: String, bundlePath: String, name: String, launchIfClosed: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.name = name
        self.launchIfClosed = launchIfClosed
    }
}

public enum ShortcutTarget: Codable, Equatable {
    case application(ApplicationShortcutTarget)
}

public struct ShortcutBinding: Codable, Equatable, Identifiable {
    public let id: UUID
    public var enabled: Bool
    public var shortcut: KeyboardShortcut?
    public var target: ShortcutTarget
    public init(id: UUID = UUID(), enabled: Bool = true, shortcut: KeyboardShortcut? = nil, target: ShortcutTarget) {
        self.id = id
        self.enabled = enabled
        self.shortcut = shortcut
        self.target = target
    }
}

public struct ShortcutConfiguration: Codable {
    public var version = 1
    public var bindings: [ShortcutBinding]
    public init(bindings: [ShortcutBinding] = []) { self.bindings = bindings }

    private enum CodingKeys: String, CodingKey { case version, bindings }
    private struct SavedBinding: Decodable {
        let value: ShortcutBinding?
        init(from decoder: Decoder) throws { value = try? ShortcutBinding(from: decoder) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // Ignore removed destination types individually so an old desktop binding
        // cannot discard the user's remaining application shortcuts.
        bindings = try container.decode([SavedBinding].self, forKey: .bindings).compactMap(\.value)
    }

    public func validationError(for binding: ShortcutBinding) -> String? {
        guard let shortcut = binding.shortcut else { return "Record a shortcut to enable this destination." }
        if let error = shortcut.validationError { return error }
        let others = bindings.filter { $0.id != binding.id }
        if others.contains(where: { $0.shortcut == shortcut }) {
            return "This shortcut is already assigned to another destination."
        }
        switch binding.target {
        case .application(let app):
            if app.bundleIdentifier.isEmpty || app.bundlePath.isEmpty { return "Choose an application." }
        }
        return nil
    }

    public var activeBindings: [ShortcutBinding] {
        guard version == 1 else { return [] }
        // Corrupt or conflicting saved records must fail closed, not hijack input.
        let ids = Dictionary(grouping: bindings, by: \.id)
        return bindings.filter { $0.enabled && ids[$0.id]?.count == 1 && validationError(for: $0) == nil }
    }
}

/// Keep a stable cycle when raising a window changes an application's AX order.
public struct WindowCycle<Identity: Equatable> {
    public private(set) var order: [Identity] = []
    public init() {}
    public mutating func next(incoming: [Identity], focused: Identity?) -> Identity? {
        let updated = order.filter { incoming.contains($0) } + incoming.filter { !order.contains($0) }
        // Do not truncate large apps, or retain an unbounded second metadata list.
        order = updated.count <= 64 ? updated : []
        guard !updated.isEmpty else { return nil }
        guard let focused, let index = updated.firstIndex(of: focused) else { return updated.first }
        return updated[(index + 1) % updated.count]
    }
}
