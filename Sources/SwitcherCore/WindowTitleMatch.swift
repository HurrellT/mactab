public enum WindowTitleMatch {
    public static func matches(window: String, menu: String) -> Bool {
        guard !window.isEmpty, !menu.isEmpty else { return false }
        return window == menu || window.hasPrefix(menu + " - ")
    }
}
