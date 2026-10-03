public enum WindowVisibility {
    /// Published AX windows retain the original current-Spaces behavior,
    /// including covered and minimized windows when requested.
    public static func includes(allSpaces: Bool, publishedByAccessibility: Bool,
                                onScreen: Bool, minimized: Bool, includeMinimized: Bool) -> Bool {
        guard includeMinimized || !minimized else { return false }
        return allSpaces || publishedByAccessibility || onScreen
    }
}
