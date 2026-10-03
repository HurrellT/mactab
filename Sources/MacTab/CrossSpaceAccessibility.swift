import ApplicationServices
import Foundation
import Darwin

/// macOS omits off-Space roots from AXWindows. Keep the two undocumented bridges
/// isolated and dynamically resolved, so an OS change cannot prevent app launch.
final class CrossSpaceAccessibility {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias TokenFunction = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
    private lazy var getWindow: WindowIDFunction? = symbol("_AXUIElementGetWindow", as: WindowIDFunction.self)
    private lazy var createElement: TokenFunction? = symbol("_AXUIElementCreateWithRemoteToken", as: TokenFunction.self)
    private var cursors: [pid_t: UInt64] = [:]
    var isAvailable: Bool { getWindow != nil && createElement != nil }

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    func recover(pid: pid_t, ids: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        guard !ids.isEmpty, let createElement,
              let token = CFDataCreateMutable(nil, 20) else { return [:] }
        CFDataSetLength(token, 20)
        guard let buffer = CFDataGetMutableBytePtr(token) else { return [:] }
        buffer.initialize(repeating: 0, count: 20)
        var process = pid
        withUnsafeBytes(of: &process) { buffer.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 4) }
        var cocoaTag: UInt32 = 0x636f636f
        withUnsafeBytes(of: &cocoaTag) { (buffer + 8).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 4) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        var candidateID = cursors[pid] ?? 0
        var missing = ids
        var found: [CGWindowID: AXUIElement] = [:]
        while DispatchTime.now().uptimeNanoseconds < deadline, !missing.isEmpty {
            withUnsafeBytes(of: &candidateID) { (buffer + 12).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 8) }
            candidateID &+= 1
            guard let candidate = createElement(token)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(candidate, 0.02)
            guard let id = windowID(candidate), missing.contains(id),
                  WindowService.attribute(candidate, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
            found[id] = candidate
            missing.remove(id)
        }
        // Continue the next on-demand scan past sparse IDs in a long-lived app.
        cursors[pid] = missing.isEmpty || candidateID > 1_000_000 ? 0 : candidateID
        return found
    }

    func forget(_ pid: pid_t) { cursors.removeValue(forKey: pid) }
    deinit { if let library { dlclose(library) } }
}
