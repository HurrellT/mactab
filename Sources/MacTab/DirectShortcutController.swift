import AppKit
import SwitcherCore

protocol ShortcutWindowServicing {
    func windows(for pid: pid_t, includeMinimized: Bool, remember: Bool, allSpaces: Bool,
                 startingAtFocusedWindow: Bool, completion: @escaping ([WindowItem], Int, Bool) -> Void)
    func focus(_ window: WindowItem?, application: NSRunningApplication, remember: Bool,
               cancellation: ActionCancellation?, completion: @escaping (Bool) -> Void)
}

struct ShortcutApplicationEnvironment {
    var runningApplication: (String) -> NSRunningApplication? = { identifier in
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == identifier && !$0.isTerminated }
    }
    var isFrontmost: (NSRunningApplication) -> Bool = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier
    }
    var isOwnApplication: (NSRunningApplication) -> Bool = { $0.processIdentifier == getpid() }
    var resolveApplication: (ApplicationShortcutTarget) -> URL? = { target in
        let saved = URL(fileURLWithPath: target.bundlePath)
        return Bundle(url: saved)?.bundleIdentifier == target.bundleIdentifier ? saved :
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier)
    }
    var launch: (URL, @escaping (NSRunningApplication?, Error?) -> Void) -> Void = { url, completion in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
    }
}

/// Direct actions share the switcher's AX service, but never build an overlay or previews.
final class DirectShortcutController {
    private let preferences: Preferences
    private let windows: ShortcutWindowServicing
    private let environment: ShortcutApplicationEnvironment
    private var binding: ShortcutBinding?
    private var pendingPresses = 0
    private var busy = false
    private var generation = 0
    private var cancellation = ActionCancellation()
    private var activatedInSequence = false
    private var cycle = WindowCycle<WindowIdentity>()
    private var cyclePID: pid_t?
    private var cycleTime: TimeInterval = 0
    var onError: ((String) -> Void)?

    init(preferences: Preferences, windows: ShortcutWindowServicing,
         environment: ShortcutApplicationEnvironment = ShortcutApplicationEnvironment()) {
        self.preferences = preferences
        self.windows = windows
        self.environment = environment
    }

    func cancel() {
        guard busy || binding != nil else { return }
        generation += 1
        cancellation.cancel()
        cancellation = ActionCancellation()
        binding = nil
        pendingPresses = 0
        busy = false
        activatedInSequence = false
    }

    func forget(_ pid: pid_t) {
        if cyclePID == pid { cycle = WindowCycle(); cyclePID = nil }
    }

    func perform(_ incoming: ShortcutBinding) {
        if binding?.id != incoming.id {
            cancel()
            binding = incoming
        }
        pendingPresses = min(pendingPresses + 1, 64)
        drain()
    }

    private func drain() {
        guard !busy, pendingPresses > 0, let binding else { return }
        busy = true
        pendingPresses -= 1
        let token = generation
        // Never resolve apps or call AX inside the event-tap callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == token else { return }
            switch binding.target {
            case .application(let target): performApplication(target, token: token)
            }
        }
    }

    private func performApplication(_ target: ApplicationShortcutTarget, token: Int) {
        if let app = environment.runningApplication(target.bundleIdentifier) {
            use(app, token: token)
            return
        }
        guard target.launchIfClosed else { fail("\(target.name) is not running.", token: token); return }
        guard let url = environment.resolveApplication(target) else {
            fail("\(target.name) could not be found. Choose its application again in Shortcuts.", token: token)
            return
        }
        environment.launch(url) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard let app else { self.fail(error?.localizedDescription ?? "The application could not launch.", token: token); return }
                // The launch is the first activation, even if the app makes itself frontmost.
                self.focus(nil, application: app, token: token)
            }
        }
    }

    private func use(_ app: NSRunningApplication, token: Int) {
        guard !environment.isOwnApplication(app) else { fail("Choose an application other than MacTab.", token: token); return }
        let isFrontmost = environment.isFrontmost(app)
        guard isFrontmost || activatedInSequence else {
            focus(nil, application: app, token: token)
            return
        }
        windows.windows(for: app.processIdentifier, includeMinimized: preferences.includeMinimized,
                        remember: preferences.rememberWindows, allSpaces: preferences.allSpaces,
                        startingAtFocusedWindow: true) { [weak self] incoming, preferred, isFinal in
            guard let self, generation == token, isFinal else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if cyclePID != app.processIdentifier || now - cycleTime >= 30 { cycle = WindowCycle() }
            cyclePID = app.processIdentifier
            cycleTime = now
            let focused = incoming.indices.contains(preferred) ? incoming[preferred].identity : nil
            let next = cycle.next(incoming: incoming.map(\.identity), focused: focused)
            let window = next.flatMap { id in incoming.first { $0.identity == id } }
            focus(window, application: app, token: token)
        }
    }

    private func focus(_ window: WindowItem?, application app: NSRunningApplication, token: Int) {
        windows.focus(window, application: app, remember: preferences.rememberWindows, cancellation: cancellation) { [weak self] success in
            guard let self, generation == token else { return }
            if success { activatedInSequence = true; finish(token: token) }
            else { fail("MacTab could not focus the selected window of \(app.localizedName ?? "the application").", token: token) }
        }
    }

    private func finish(token: Int) {
        guard generation == token else { return }
        busy = false
        if pendingPresses > 0 { drain() }
        else { binding = nil; activatedInSequence = false }
    }

    private func fail(_ message: String, token: Int) {
        guard generation == token else { return }
        cancel()
        onError?(message)
    }
}
