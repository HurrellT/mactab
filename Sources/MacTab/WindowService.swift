import AppKit
import ApplicationServices
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
}

private struct ServerWindow {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let onScreen: Bool
}

/// All cross-process work runs off the event tap/main thread. Nothing polls while idle.
final class WindowService {
    private let queue = DispatchQueue(label: "com.mactab.accessibility", qos: .userInitiated)
    private let crossSpace = CrossSpaceAccessibility()
    private var remembered: [pid_t: AXUIElement] = [:]
    private var cached: [pid_t: [CGWindowID: AXUIElement]] = [:]
    private var observer: AXObserver?
    private var observedPID: pid_t?

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
        recordFocused(pid)
    }

    func recordFocused(_ pid: pid_t) {
        queue.async { [self] in
            let app = application(pid)
            // References acquired on a Space remain usable after leaving it, notably in Chromium.
            var elements = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let value = Self.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let focused = value as! AXUIElement
                remembered[pid] = focused
                elements.append(focused)
            }
            for element in elements {
                if let id = crossSpace.windowID(element) { cached[pid, default: [:]][id] = element }
            }
        }
    }

    func forget(_ pid: pid_t) {
        queue.async { [self] in
            remembered.removeValue(forKey: pid)
            cached.removeValue(forKey: pid)
            crossSpace.forget(pid)
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
                 completion: @escaping ([WindowItem], Int) -> Void) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let displays = NSScreen.screens.enumerated().map { index, screen in
            (CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                    width: screen.frame.width, height: screen.frame.height), "Display \(index + 1)")
        }
        queue.async { [self] in
            let app = application(pid)
            let published = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let inventory = serverWindows(pid)
            let byID = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var elements: [CGWindowID: AXUIElement] = [:]
            var publishedIDs = Set<CGWindowID>()
            for element in published {
                if let id = crossSpace.windowID(element) {
                    elements[id] = element
                    publishedIDs.insert(id)
                    cached[pid, default: [:]][id] = element
                }
            }
            // Retain only IDs that still exist in this process's current inventory.
            cached[pid] = cached[pid, default: [:]].filter { byID[$0.key] != nil || publishedIDs.contains($0.key) }
            if allSpaces {
                for (id, element) in cached[pid, default: [:]] { elements[id] = element }
                let missing = Set(byID.keys).subtracting(elements.keys)
                for (id, element) in crossSpace.recover(pid: pid, ids: missing) {
                    elements[id] = element
                    cached[pid, default: [:]][id] = element
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
            for element in published { append(element, id: crossSpace.windowID(element), published: true) }
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
            // Direct Cmd+` cycles relative to the actual focused window, independently
            // of the preference for restoring remembered windows during app switching.
            var previous = remember ? remembered[pid] : nil
            if startingAtFocusedWindow,
               let value = Self.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                previous = (value as! AXUIElement)
            }
            let previousID = previous.flatMap { crossSpace.windowID($0) }
            let preferred = result.firstIndex(where: { item in
                if let element = item.element, let previous, CFEqual(element, previous) { return true }
                return previousID != nil && item.windowID == previousID
            }) ?? 0
            DispatchQueue.main.async { completion(result, preferred) }
        }
    }

    private func describe(_ element: AXUIElement, id: CGWindowID?, server: ServerWindow?,
                          displays: [(CGRect, String)]) -> WindowItem? {
        guard Self.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole,
              Self.attribute(element, kAXSubroleAttribute) as? String != kAXSystemDialogSubrole else { return nil }
        let minimized = Self.attribute(element, kAXMinimizedAttribute) as? Bool ?? false
        let title = Self.attribute(element, kAXTitleAttribute) as? String ?? server?.title ?? ""
        var position = server?.frame.origin ?? .zero
        var size = server?.frame.size ?? .zero
        if let value = Self.attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        if let value = Self.attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
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

    func focus(_ window: WindowItem?, application app: NSRunningApplication, remember: Bool,
               completion: @escaping (Bool) -> Void) {
        let pid = app.processIdentifier
        queue.async { [self] in
            var target = window?.element ?? (window == nil && remember ? remembered[pid] : nil)
            if target == nil, window?.menuItem == nil, let id = window?.windowID {
                target = cached[pid]?[id] ?? crossSpace.recover(pid: pid, ids: [id])[id]
            }
            if let target {
                AXUIElementSetMessagingTimeout(target, 0.15)
                AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let resolvedTarget = target
            DispatchQueue.main.async {
                guard !app.isTerminated else { completion(false); return }
                app.activate(options: [])
                self.queue.async {
                    var raised = window == nil
                    if let target = resolvedTarget {
                        let root = self.application(pid)
                        AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, target)
                        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
                        raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
                        if raised {
                            self.remembered[pid] = target
                            if let id = self.crossSpace.windowID(target) { self.cached[pid, default: [:]][id] = target }
                        } else { self.remembered.removeValue(forKey: pid) }
                    }
                    if !raised, let window {
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
                    DispatchQueue.main.async { completion(raised || window == nil) }
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
