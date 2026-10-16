import AppKit
import ApplicationServices
import OSLog
import SwitcherCore

struct WindowItem {
    let element: AXUIElement?
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let displayName: String
    var windowID: CGWindowID? = nil
    var isOnCurrentSpace: Bool = true
    var menuItem: AXUIElement? = nil

    var identity: WindowIdentity {
        if let windowID { return .server(windowID) }
        if let element = element ?? menuItem { return .accessibility(element) }
        return .fallback(title, frame)
    }
}

enum WindowIdentity: Equatable {
    case server(CGWindowID)
    case accessibility(AXUIElement)
    case fallback(String, CGRect)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.server(let a), .server(let b)): return a == b
        case (.accessibility(let a), .accessibility(let b)): return CFEqual(a, b)
        case (.fallback(let at, let af), .fallback(let bt, let bf)): return at == bt && af == bf
        default: return false
        }
    }
}

private struct WindowSnapshotKey: Equatable {
    let pid: pid_t
    let includeMinimized: Bool
    let allSpaces: Bool
    let displays: [CGRect]
    let inventory: Set<CGWindowID>
    let published: Set<CGWindowID>
    let minimized: Set<CGWindowID>
}

private struct ServerWindow {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let onScreen: Bool
}

/// All cross-process work runs off the event tap/main thread. Nothing polls while idle.
final class WindowService: ShortcutWindowServicing {
    private let queue = DispatchQueue(label: "com.mactab.accessibility", qos: .userInitiated)
    private let crossSpace = CrossSpaceAccessibility()
    private var remembered: [pid_t: AXUIElement] = [:]
    private var focusHistory: [pid_t: WindowFocusHistory<WindowIdentity>] = [:]
    private var cached: [pid_t: [CGWindowID: AXUIElement]] = [:]
    private var snapshots = WindowSnapshotCache<WindowSnapshotKey, WindowItem>()
    private var recoveryAttempt: (pid: pid_t, ids: Set<CGWindowID>, time: Double)?
    private let timings = CommandLine.arguments.contains("--window-timing")
    private let logger = Logger(subsystem: "com.tlh.mactab", category: "window-discovery")
    private var observer: AXObserver?
    private var observedPID: pid_t?

    init() {
        // Application-root timeouts do not apply to its child window/menu elements.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return app
    }

    func observeFrontmost(_ pid: pid_t) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = pid
        guard AXIsProcessTrusted() else { return }
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let service = Unmanaged<WindowService>.fromOpaque(context).takeUnretainedValue()
            if let pid = service.observedPID { service.recordFocused(pid) }
        }, &newObserver)
        guard result == .success, let newObserver else { return }
        observer = newObserver
        let app = application(pid)
        AXObserverAddNotification(newObserver, app, kAXFocusedWindowChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        recordFocused(pid, includeWindows: true)
    }

    func recordFocused(_ pid: pid_t, includeWindows: Bool = false) {
        queue.async { [self] in
            let app = application(pid)
            // References acquired on a Space remain usable after leaving it, notably in Chromium.
            // Seed other-Space references on activation, not on every focus change.
            var elements = includeWindows ? Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] : []
            if let value = Self.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let focused = value as! AXUIElement
                rememberFocus(focused, pid: pid)
                elements.append(focused)
            }
            for element in elements {
                if let id = crossSpace.windowID(element) { cached[pid, default: [:]][id] = element }
            }
        }
    }

    // Called only on the accessibility queue, including focus changes outside MacTab.
    private func rememberFocus(_ element: AXUIElement, pid: pid_t) {
        remembered[pid] = element
        let identity = crossSpace.windowID(element).map(WindowIdentity.server) ?? .accessibility(element)
        focusHistory[pid, default: WindowFocusHistory()].record(identity)
    }

    func forget(_ pid: pid_t) {
        queue.async { [self] in
            remembered.removeValue(forKey: pid)
            focusHistory.removeValue(forKey: pid)
            cached.removeValue(forKey: pid)
            crossSpace.forget(pid)
            if snapshots.key?.pid == pid { snapshots.clear() }
            if recoveryAttempt?.pid == pid { recoveryAttempt = nil }
        }
        if observedPID == pid {
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            observer = nil
            observedPID = nil
        }
    }

    private func serverWindows(_ pid: pid_t) -> [ServerWindow] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { return nil }
            return ServerWindow(id: id, title: entry[kCGWindowName as String] as? String ?? "",
                                frame: frame, onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    func windows(for pid: pid_t, includeMinimized: Bool, remember: Bool, allSpaces: Bool,
                 startingAtFocusedWindow: Bool = false,
                 completion: @escaping ([WindowItem], Int, Bool) -> Void) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let displays = NSScreen.screens.enumerated().map { index, screen in
            (CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                    width: screen.frame.width, height: screen.frame.height), "Display \(index + 1)")
        }
        let requestedAt = Self.uptime
        queue.async { [self] in
            let started = Self.uptime
            let app = application(pid)
            let published = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let inventory = serverWindows(pid)
            let byID = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var elements: [CGWindowID: AXUIElement] = [:]
            var publishedIDs = Set<CGWindowID>()
            let publishedWindows = published.map { (element: $0, id: crossSpace.windowID($0)) }
            for (element, id) in publishedWindows {
                if let id {
                    elements[id] = element
                    publishedIDs.insert(id)
                    cached[pid, default: [:]][id] = element
                }
            }
            var minimizedIDs = Set<CGWindowID>()
            if !includeMinimized {
                var candidates = elements
                if allSpaces {
                    for (id, element) in cached[pid, default: [:]] where candidates[id] == nil && byID[id] != nil {
                        candidates[id] = element
                    }
                }
                for (id, element) in candidates where Self.attribute(element, kAXMinimizedAttribute) as? Bool == true {
                    minimizedIDs.insert(id)
                }
            }
            // A new/closed window or a current-Space list change needs a fresh list
            // before applying the first shortcut step, rather than an incomplete cycle.
            let key = WindowSnapshotKey(pid: pid, includeMinimized: includeMinimized, allSpaces: allSpaces,
                                        displays: displays.map { $0.0 }, inventory: Set(byID.keys).union(publishedIDs),
                                        published: allSpaces ? [] : publishedIDs, minimized: minimizedIDs)
            // Read the real focus before presenting cached cards. A stale remembered
            // index must never make the first standalone shortcut advance incorrectly.
            var previous = remember ? remembered[pid] : nil
            if startingAtFocusedWindow,
               let value = Self.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let focused = value as! AXUIElement
                previous = focused
                rememberFocus(focused, pid: pid)
            }
            let previousID = previous.flatMap { crossSpace.windowID($0) }
            let focusedIdentity = previous.map { element in
                previousID.map(WindowIdentity.server) ?? .accessibility(element)
            }
            // Capture one order for both cached cards and fresh discovery. Quick release
            // and holding the overlay must choose the same previously viewed window.
            let history = focusHistory[pid] ?? WindowFocusHistory()
            func ordered(_ items: [WindowItem]) -> [WindowItem] {
                guard remember, startingAtFocusedWindow else { return items }
                return history.ordered(items, identity: \.identity, focused: focusedIdentity)
            }
            func preferredIndex(_ items: [WindowItem]) -> Int? {
                items.firstIndex { item in
                    if let element = item.element, let previous, CFEqual(element, previous) { return true }
                    return previousID != nil && item.windowID == previousID
                }
            }
            var cacheHit = false
            if let snapshot = snapshots.value(for: key, now: started) {
                let cards = ordered(snapshot.compactMap { original -> WindowItem? in
                    let isPublished = original.windowID.map { publishedIDs.contains($0) } ??
                        original.element.map { element in published.contains { CFEqual($0, element) } } ?? false
                    let server = original.windowID.flatMap { byID[$0] }
                    // Do not display closed cards, or carry visibility across Space changes.
                    guard server != nil || isPublished else { return nil }
                    guard WindowVisibility.includes(allSpaces: allSpaces, publishedByAccessibility: isPublished,
                                                    onScreen: server?.onScreen ?? false, minimized: original.isMinimized,
                                                    includeMinimized: includeMinimized) else { return nil }
                    var card = original
                    card.isOnCurrentSpace = isPublished || (server?.onScreen ?? false)
                    return card
                })
                let preferred = preferredIndex(cards)
                // Newly focused windows need full discovery before cycling from them.
                let knownMinimizedState = includeMinimized || !publishedWindows.contains { $0.id == nil }
                if !cards.isEmpty, knownMinimizedState, !startingAtFocusedWindow || preferred != nil {
                    cacheHit = true
                    DispatchQueue.main.async { completion(cards, preferred ?? 0, false) }
                    if timings {
                        logger.info("Cached cards: pid=\(pid) count=\(cards.count) first_ms=\((Self.uptime - requestedAt) * 1000)")
                    }
                }
            }
            // Retain only IDs that still exist in this process's current inventory.
            cached[pid] = cached[pid, default: [:]].filter { byID[$0.key] != nil || publishedIDs.contains($0.key) }
            if allSpaces {
                for (id, element) in cached[pid, default: [:]] { elements[id] = element }
                let missing = Set(byID.keys).subtracting(elements.keys)
                // An unchanged unresolved inventory should not trigger a 200 ms scan
                // on every key press. Retry on new IDs or after five seconds, on demand.
                let retry = recoveryAttempt.map { $0.pid != pid || $0.ids != missing || started - $0.time >= 5 } ?? true
                if !missing.isEmpty, retry {
                    let recovered = crossSpace.recover(pid: pid, ids: missing)
                    recoveryAttempt = (pid, missing.subtracting(recovered.keys), Self.uptime)
                    for (id, element) in recovered {
                        elements[id] = element
                        cached[pid, default: [:]][id] = element
                    }
                } else if missing.isEmpty, recoveryAttempt?.pid == pid {
                    recoveryAttempt = nil
                }
            }
            let menu = allSpaces && byID.keys.contains(where: { elements[$0] == nil }) ? windowMenuEntries(app) : []
            var result: [WindowItem] = []
            var unnamed: [ServerWindow] = []
            var rejected = Set<CGWindowID>()
            func append(_ element: AXUIElement, id: CGWindowID?, published: Bool) {
                guard var item = self.describe(element, id: id, server: id.flatMap { byID[$0] }, displays: displays) else {
                    if let id { rejected.insert(id); self.cached[pid]?.removeValue(forKey: id) }
                    return
                }
                item.isOnCurrentSpace = published || (id.flatMap { byID[$0]?.onScreen } ?? false)
                if WindowVisibility.includes(allSpaces: allSpaces, publishedByAccessibility: published,
                                             onScreen: id.flatMap { byID[$0]?.onScreen } ?? false,
                                             minimized: item.isMinimized, includeMinimized: includeMinimized) {
                    result.append(item)
                }
            }
            // Preserve the app's AX order first, then add other Spaces in WindowServer order.
            for (element, id) in publishedWindows { append(element, id: id, published: true) }
            for server in inventory where !publishedIDs.contains(server.id) && allSpaces {
                if let element = elements[server.id] { append(element, id: server.id, published: false) }
                else if !rejected.contains(server.id), server.frame.width >= 80, server.frame.height >= 80 {
                    if server.title.isEmpty { unnamed.append(server); continue }
                    // Chromium can publish no off-Space AX root at all. A Window-menu action
                    // provides a public focus route; otherwise keep its CG identity for retry.
                    let matchingMenu = menu.filter { WindowTitleMatch.matches(window: server.title, menu: $0.title) }
                    let entry = matchingMenu.count == 1 ? matchingMenu.first : nil
                    result.append(WindowItem(element: nil, title: server.title.isEmpty ? "Untitled window" : server.title,
                                             frame: server.frame, isMinimized: false,
                                             displayName: Self.displayName(server.frame, displays), windowID: server.id,
                                             isOnCurrentSpace: server.onScreen, menuItem: entry?.element))
                }
            }
            // CG redacts titles without Screen Recording. The app's own Window menu
            // still names its windows, without requesting a recording permission.
            let extraMenuWindows = menu.filter { entry in
                !result.contains { WindowTitleMatch.matches(window: $0.title, menu: entry.title) }
            }
            if !unnamed.isEmpty, !extraMenuWindows.isEmpty {
                for entry in extraMenuWindows {
                    result.append(WindowItem(element: nil, title: entry.title, frame: .zero, isMinimized: false,
                                             displayName: "Other Space", isOnCurrentSpace: false, menuItem: entry.element))
                }
            } else {
                for server in unnamed {
                    result.append(WindowItem(element: nil, title: "Untitled window", frame: server.frame, isMinimized: false,
                                             displayName: Self.displayName(server.frame, displays), windowID: server.id,
                                             isOnCurrentSpace: server.onScreen))
                }
            }
            result = ordered(result)
            if allSpaces {
                // Prune closed windows, retaining history for windows hidden by preferences.
                let live = inventory.map { WindowIdentity.server($0.id) } + publishedWindows.map { element, id in
                    id.map(WindowIdentity.server) ?? .accessibility(element)
                }
                focusHistory[pid]?.retain(live)
            }
            let preferred = preferredIndex(result) ?? 0
            snapshots.store(result, for: key, now: Self.uptime)
            if timings {
                // Payload estimate excludes opaque AX objects and allocator overhead.
                let payload = snapshots.key == key ? result.count * MemoryLayout<WindowItem>.stride +
                    result.reduce(0) { $0 + $1.title.utf8.count + $1.displayName.utf8.count } : 0
                logger.info("Window refresh: pid=\(pid) cache_hit=\(cacheHit) count=\(result.count) total_ms=\((Self.uptime - requestedAt) * 1000) metadata_bytes_estimate=\(payload)")
            }
            DispatchQueue.main.async { completion(result, preferred, true) }
        }
    }

    private static var uptime: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    private func describe(_ element: AXUIElement, id: CGWindowID?, server: ServerWindow?,
                          displays: [(CGRect, String)]) -> WindowItem? {
        // Recovered roots use a shorter timeout while scanning; metadata gets the
        // normal timeout once the root is known to belong to a requested window.
        AXUIElementSetMessagingTimeout(element, 0.15)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute,
                     kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute]
        var copied: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &copied)
        let values: [Any]
        if status == .success, let copied, CFArrayGetCount(copied) == names.count {
            values = copied as! [Any]
        } else if status == .notImplemented || status == .attributeUnsupported {
            // Some custom accessibility implementations only support individual reads.
            values = names.map { Self.attribute(element, $0) ?? NSNull() }
        } else { return nil }
        guard values[0] as? String == kAXWindowRole,
              values[1] as? String != kAXSystemDialogSubrole else { return nil }
        let minimized = values[2] as? Bool ?? false
        let title = values[3] as? String ?? server?.title ?? ""
        var position = server?.frame.origin ?? .zero
        var size = server?.frame.size ?? .zero
        if CFGetTypeID(values[4] as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(values[4] as! AXValue, .cgPoint, &position)
        }
        if CFGetTypeID(values[5] as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(values[5] as! AXValue, .cgSize, &size)
        }
        guard size.width > 1, size.height > 1 else { return nil }
        let frame = CGRect(origin: position, size: size)
        return WindowItem(element: element, title: title.isEmpty ? "Untitled window" : title, frame: frame,
                          isMinimized: minimized, displayName: Self.displayName(frame, displays), windowID: id,
                          isOnCurrentSpace: server?.onScreen ?? true)
    }

    private struct MenuWindow {
        let title: String
        let element: AXUIElement
    }

    private func windowMenuEntries(_ app: AXUIElement) -> [MenuWindow] {
        guard let value = Self.attribute(app, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let bar = value as! AXUIElement
        let menus = Self.attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for menu in menus {
            let children = Self.attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children {
                let items = Self.attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? []
                let entries = items.filter {
                    Self.attribute($0, kAXIdentifierAttribute) as? String == "makeKeyAndOrderFront:"
                }.compactMap { item -> MenuWindow? in
                    guard let title = Self.attribute(item, kAXTitleAttribute) as? String, !title.isEmpty,
                          Self.attribute(item, kAXEnabledAttribute) as? Bool != false else { return nil }
                    return MenuWindow(title: title, element: item)
                }
                if !entries.isEmpty { return entries }
            }
        }
        return []
    }

    func focus(_ requestedWindow: WindowItem?, application app: NSRunningApplication, remember: Bool,
               cancellation: ActionCancellation? = nil,
               completion: @escaping (Bool) -> Void) {
        let pid = app.processIdentifier
        queue.async { [self] in
            guard !app.isTerminated, cancellation?.isCancelled != true else { DispatchQueue.main.async { completion(false) }; return }
            var window = requestedWindow
            // Discovery queued before this activation may have refreshed a cached card.
            if let key = snapshots.key, key.pid == pid,
               let current = snapshots.value(for: key, now: Self.uptime), let requestedWindow,
               let updated = current.first(where: { $0.identity == requestedWindow.identity }) {
                window = updated
            }
            var target = window?.element ?? (window == nil && remember ? remembered[pid] : nil)
            if let element = target {
                let validRole = Self.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole
                let validID = window?.windowID.map { crossSpace.windowID(element) == $0 } ?? true
                if !validRole || !validID {
                    target = nil
                    if let id = window?.windowID { cached[pid]?.removeValue(forKey: id) }
                }
            }
            // A closed cached card must not fall through to activating an arbitrary window.
            if target == nil, let id = window?.windowID, !serverWindows(pid).contains(where: { $0.id == id }) {
                DispatchQueue.main.async { completion(false) }
                return
            }
            if target == nil, window?.menuItem == nil, let id = window?.windowID {
                target = cached[pid]?[id] ?? crossSpace.recover(pid: pid, ids: [id])[id]
            }
            if let target {
                guard cancellation?.isCancelled != true else { DispatchQueue.main.async { completion(false) }; return }
                AXUIElementSetMessagingTimeout(target, 0.15)
                AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let resolvedTarget = target
            let resolvedWindow = window
            DispatchQueue.main.async {
                guard !app.isTerminated, cancellation?.isCancelled != true else { completion(false); return }
                app.activate(options: [])
                self.queue.async {
                    guard cancellation?.isCancelled != true else { DispatchQueue.main.async { completion(false) }; return }
                    var raised = resolvedWindow == nil
                    if let target = resolvedTarget {
                        let root = self.application(pid)
                        AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, target)
                        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
                        raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
                        if raised {
                            self.rememberFocus(target, pid: pid)
                            if let id = self.crossSpace.windowID(target) { self.cached[pid, default: [:]][id] = target }
                        } else { self.remembered.removeValue(forKey: pid) }
                    }
                    if !raised, let window = resolvedWindow {
                        let entries = self.windowMenuEntries(self.application(pid)).filter {
                            WindowTitleMatch.matches(window: window.title, menu: $0.title)
                        }
                        // Duplicate titles never select an arbitrary window.
                        if entries.count == 1, let entry = entries.first {
                            raised = AXUIElementPerformAction(entry.element, kAXPressAction as CFString) == .success
                        } else if entries.isEmpty, let menuItem = window.menuItem {
                            raised = AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
                        }
                    }
                    DispatchQueue.main.async { completion(raised || resolvedWindow == nil) }
                }
            }
        }
    }

    private static func displayName(_ frame: CGRect, _ displays: [(CGRect, String)]) -> String {
        displays.max { overlap(frame, $0.0) < overlap(frame, $1.0) }?.1 ?? "Display"
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
}
