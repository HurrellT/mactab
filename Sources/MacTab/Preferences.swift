import Foundation
import SwitcherCore

final class Preferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    var shortcuts: ShortcutConfiguration {
        get {
            guard let data = defaults.data(forKey: "shortcuts"),
                  let value = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data) else {
                return ShortcutConfiguration()
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "shortcuts") }
        }
    }
}
