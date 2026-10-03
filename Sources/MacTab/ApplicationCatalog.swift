import AppKit

struct ApplicationItem {
    let application: NSRunningApplication
    var pid: pid_t { application.processIdentifier }
    var name: String { displayName ?? application.localizedName ?? "Application" }
    let icon: NSImage
    var displayName: String? = nil
}

final class ApplicationCatalog {
    private var recent: [pid_t] = []
    private var tokens: [NSObjectProtocol] = []
    var onActivation: ((pid_t) -> Void)?
    var onTermination: ((pid_t) -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recent.removeAll { $0 == app.processIdentifier }
            self?.onTermination?(app.processIdentifier)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = NSWorkspace.shared.frontmostApplication { self?.activated(app) }
        })
        if let app = NSWorkspace.shared.frontmostApplication { activated(app) }
    }

    private func activated(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular else { return }
        recent.removeAll { $0 == app.processIdentifier }
        recent.insert(app.processIdentifier, at: 0)
        onActivation?(app.processIdentifier)
    }

    func snapshot() -> [ApplicationItem] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let live = Set(apps.map(\.processIdentifier))
        recent.removeAll { !live.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
        return apps.sorted {
            let a = ranks[$0.processIdentifier] ?? Int.max
            let b = ranks[$1.processIdentifier] ?? Int.max
            return a == b ? ($0.localizedName ?? "") < ($1.localizedName ?? "") : a < b
        }.map { ApplicationItem(application: $0, icon: $0.icon ?? NSImage(named: NSImage.applicationIconName)!) }
    }

    deinit { tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }
}
