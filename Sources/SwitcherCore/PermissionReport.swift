public enum SwitcherAvailability: Equatable {
    case ready, paused, demo, accessibilityRequired, keyboardUnavailable, secureInput
}

/// A created event tap alone does not prove that it can receive keyboard input.
public struct PermissionReport {
    public let accessibilityGranted: Bool
    public let keyboardRunning: Bool
    public let inputMonitoringGranted: Bool
    public let secureInputEnabled: Bool
    public let availability: SwitcherAvailability

    public init(accessibilityGranted: Bool, keyboardRunning: Bool, inputMonitoringGranted: Bool,
                secureInputEnabled: Bool, enabled: Bool = true, demo: Bool = false) {
        self.accessibilityGranted = accessibilityGranted
        self.keyboardRunning = keyboardRunning
        self.inputMonitoringGranted = inputMonitoringGranted
        self.secureInputEnabled = secureInputEnabled
        if demo { availability = .demo }
        else if !enabled { availability = .paused }
        else if !accessibilityGranted { availability = .accessibilityRequired }
        else if secureInputEnabled { availability = .secureInput }
        else if !keyboardRunning { availability = .keyboardUnavailable }
        else { availability = .ready }
    }
}
