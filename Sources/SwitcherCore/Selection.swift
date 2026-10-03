/// The keyboard state is independent of AppKit and Accessibility.
public struct Selection: Equatable {
    public private(set) var appCount = 0
    public private(set) var appIndex = 0
    public private(set) var windowCount = 0
    public private(set) var windowIndex = 0
    public private(set) var isExpanded = false
    public private(set) var isActive = false
    public private(set) var isWindowOnly = false

    public init() {}

    public mutating func begin(appCount: Int, backwards: Bool = false) {
        self = Selection()
        self.appCount = max(0, appCount)
        isActive = appCount > 0
        appIndex = appCount > 1 ? (backwards ? appCount - 1 : 1) : 0
    }

    public mutating func moveApp(_ offset: Int) {
        guard isActive, !isWindowOnly else { return }
        appIndex = Self.wrapped(appIndex + offset, count: appCount)
        isExpanded = false
        windowCount = 0
        windowIndex = 0
    }

    /// A standalone window session stays on the current app until dismissed.
    public mutating func beginWindows() {
        begin(appCount: 1)
        isWindowOnly = true
        expand()
    }

    public mutating func expand() {
        guard isActive else { return }
        isExpanded = true
    }

    public mutating func setWindows(count: Int, preferredIndex: Int = 0) {
        windowCount = max(0, count)
        windowIndex = min(max(0, preferredIndex), max(0, count - 1))
    }

    public mutating func moveWindow(_ offset: Int) {
        guard isActive, isExpanded else { return }
        windowIndex = Self.wrapped(windowIndex + offset, count: windowCount)
    }

    public mutating func selectApp(_ index: Int) {
        guard (0..<appCount).contains(index) else { return }
        moveApp(index - appIndex)
    }

    public mutating func selectWindow(_ index: Int) {
        guard (0..<windowCount).contains(index) else { return }
        windowIndex = index
    }

    public mutating func collapse() {
        guard !isWindowOnly else { return }
        isExpanded = false
    }
    public mutating func end() { self = Selection() }

    private static func wrapped(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((value % count) + count) % count
    }
}
