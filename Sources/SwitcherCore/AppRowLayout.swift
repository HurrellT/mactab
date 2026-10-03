/// Fit every app on the available display width before reducing icon size.
public struct AppRowLayout {
    public let width: Double
    public let tileWidth: Double
    public let iconSize: Double

    public init(appCount: Int, screenWidth: Double) {
        let count = Double(max(1, appCount))
        let available = max(33, screenWidth - 48)
        width = min(max(420, count * 120 + 32), available)
        tileWidth = min(120, (width - 32) / count)
        iconSize = 96 * tileWidth / 120
    }
}
