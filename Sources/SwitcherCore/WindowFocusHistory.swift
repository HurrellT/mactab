/// Recently focused windows, independent of the order reported by Accessibility or Spaces.
public struct WindowFocusHistory<Identity: Equatable> {
    private var recent: [Identity] = []

    public init() {}

    public mutating func record(_ identity: Identity) {
        recent.removeAll { $0 == identity }
        recent.insert(identity, at: 0)
        // Bound retained identities even if windows close between discovery requests.
        if recent.count > 64 { recent.removeLast(recent.count - 64) }
    }

    public mutating func retain(_ live: [Identity]) {
        recent.removeAll { !live.contains($0) }
    }

    /// Keep the actual focused window first, then previous windows, then unvisited ones.
    /// Filtering against incoming identities also respects Space/minimized preferences.
    public func ordered(_ incoming: [Identity], focused: Identity?) -> [Identity] {
        ordered(incoming, identity: { $0 }, focused: focused)
    }

    public func ordered<Item>(_ incoming: [Item], identity: (Item) -> Identity, focused: Identity?) -> [Item] {
        var visited: [Identity] = []
        var result: [Item] = []
        for recentIdentity in (focused.map { [$0] } ?? []) + recent {
            guard !visited.contains(recentIdentity),
                  let item = incoming.first(where: { identity($0) == recentIdentity }) else { continue }
            visited.append(recentIdentity)
            result.append(item)
        }
        return result + incoming.filter { !visited.contains(identity($0)) }
    }
}
