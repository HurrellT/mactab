import Foundation

final class Preferences {
    private let defaults = UserDefaults.standard
    init() {
        defaults.register(defaults: ["rememberWindows": true, "includeMinimized": true, "showPreviews": false,
                                     "allSpaces": true, "showHints": true])
    }
    var rememberWindows: Bool {
        get { defaults.bool(forKey: "rememberWindows") }
        set { defaults.set(newValue, forKey: "rememberWindows") }
    }
    var includeMinimized: Bool {
        get { defaults.bool(forKey: "includeMinimized") }
        set { defaults.set(newValue, forKey: "includeMinimized") }
    }
    var showPreviews: Bool {
        get { defaults.bool(forKey: "showPreviews") }
        set { defaults.set(newValue, forKey: "showPreviews") }
    }
    var allSpaces: Bool {
        get { defaults.bool(forKey: "allSpaces") }
        set { defaults.set(newValue, forKey: "allSpaces") }
    }
    var showHints: Bool {
        get { defaults.bool(forKey: "showHints") }
        set { defaults.set(newValue, forKey: "showHints") }
    }
}
