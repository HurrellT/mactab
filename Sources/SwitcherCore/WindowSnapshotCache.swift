/// A single, bounded metadata snapshot. Expiration is checked on access, never by a timer.
public struct WindowSnapshotCache<Key: Equatable, Item> {
    public private(set) var key: Key?
    private var items: [Item] = []
    private var storedAt: Double = 0
    private let capacity: Int
    private let lifetime: Double

    public init(capacity: Int = 64, lifetime: Double = 30) {
        self.capacity = max(0, capacity)
        self.lifetime = max(0, lifetime)
    }

    public mutating func store(_ items: [Item], for key: Key, now: Double) {
        // Never truncate a window list: that could change which window a shortcut selects.
        guard !items.isEmpty, items.count <= capacity else { clear(); return }
        self.key = key
        self.items = items
        storedAt = now
    }

    public mutating func value(for key: Key, now: Double) -> [Item]? {
        guard self.key == key, now >= storedAt, now - storedAt < lifetime else {
            clear()
            return nil
        }
        return items
    }

    public mutating func clear() {
        key = nil
        items = []
        storedAt = 0
    }
}
