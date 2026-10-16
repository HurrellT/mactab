import AppKit
import SwitcherCore

final class SwitcherController {
    let preferences: Preferences
    let catalog = ApplicationCatalog()
    let windowService = WindowService()
    let keyboard = KeyboardInterceptor()
    let panel = SwitcherPanel()
    private let previews = PreviewService()
    private lazy var directShortcuts = DirectShortcutController(preferences: preferences, windows: windowService)
    private var focusCancellation: ActionCancellation?
    private let presentationDelay: TimeInterval = 0.10
    private(set) var selection = Selection()
    private var apps: [ApplicationItem] = []
    private var windows: [WindowItem] = []
    private var loadedPID: pid_t?
    private var loading = false
    private var refreshingWindows = false
    private var generation = 0
    private var visiblePreviews: [Int] = []
    private var pendingWindowSteps = 0
    private struct PendingCommit {
        let token: Int
        let application: NSRunningApplication
        let steps: Int
        let remember: Bool
    }
    private var pendingCommit: PendingCommit?
    var onFocusFailure: (() -> Void)?
    var onShortcutError: ((String) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        keyboard.isSwitching = { [weak self] in self?.selection.isActive ?? false }
        keyboard.onKey = { [weak self] in self?.handle($0) }
        keyboard.onInterruption = { [weak self] in self?.cancel() }
        keyboard.onShortcut = { [weak self] binding in
            guard let self else { return }
            focusCancellation?.cancel()
            dismiss(clearPending: true)
            directShortcuts.perform(binding)
        }
        directShortcuts.onError = { [weak self] in self?.onShortcutError?($0) }
        keyboard.bindings = preferences.shortcuts.activeBindings
        catalog.onActivation = { [weak self] pid in self?.windowService.observeFrontmost(pid) }
        catalog.onTermination = { [weak self] pid in
            self?.windowService.forget(pid)
            self?.directShortcuts.forget(pid)
        }
        panel.onAppClick = { [weak self] index in
            guard let self else { return }
            selection.selectApp(index)
            windows.removeAll()
            loadedPID = nil
            commit()
        }
        panel.onWindowClick = { [weak self] index in
            guard let self else { return }
            selection.selectWindow(index)
            commit()
        }
        panel.onVisibleWindowsChanged = { [weak self] in self?.refreshPreviews() }
        panel.onPresentation = { [weak self] in self?.refreshPreviews() }
    }

    func start() -> Bool {
        let started = keyboard.start()
        if started, let app = NSWorkspace.shared.frontmostApplication {
            windowService.observeFrontmost(app.processIdentifier)
        }
        return started
    }

    func handle(_ key: SwitcherKey) {
        directShortcuts.cancel()
        focusCancellation?.cancel()
        switch key {
        case .tab(let backwards):
            if selection.isWindowOnly { cancel() }
            if !selection.isActive {
                pendingCommit = nil
                apps = catalog.snapshot()
                selection.begin(appCount: apps.count, backwards: backwards)
                guard selection.isActive else { return }
                panel.showHints = preferences.showHints
                panel.show(apps: apps, selected: selection.appIndex, presentationDelay: presentationDelay)
            } else {
                selection.moveApp(backwards ? -1 : 1)
                invalidateWindows()
                panel.updateAppSelection(selection.appIndex)
                panel.collapse()
            }
        case .grave(let backwards):
            if !selection.isActive { beginCurrentAppWindows(backwards: backwards) }
            else if selection.isExpanded { moveWindow(backwards ? -1 : 1) }
            else { expand() }
        case .down: expand()
        case .up:
            guard !selection.isWindowOnly else { return }
            selection.collapse()
            previews.cancel()
            panel.collapse()
        case .left, .right:
            let offset = key.isLeft ? -1 : 1
            if selection.isExpanded { moveWindow(offset) }
            else {
                selection.moveApp(offset)
                invalidateWindows()
                panel.updateAppSelection(selection.appIndex)
            }
        case .accept, .release: commit()
        case .cancel: cancel()
        }
    }

    private func beginCurrentAppWindows(backwards: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !app.isTerminated, app.processIdentifier != getpid() else { return }
        cancel()
        apps = [ApplicationItem(application: app, icon: app.icon ?? NSImage(named: NSImage.applicationIconName)!)]
        selection.beginWindows()
        panel.showHints = preferences.showHints
        panel.show(apps: apps, selected: 0, windowsOnly: true, presentationDelay: presentationDelay)
        pendingWindowSteps = backwards ? -1 : 1
        expand()
    }

    private func expand() {
        guard selection.isActive, apps.indices.contains(selection.appIndex) else { return }
        selection.expand()
        let app = apps[selection.appIndex]
        if loadedPID == app.pid {
            renderWindows()
            return
        }
        guard !loading else { return }
        loading = true
        refreshingWindows = true
        let token = generation
        panel.expand(app: app, windows: [], selected: 0, remembered: nil, loading: true)
        windowService.windows(for: app.pid, includeMinimized: preferences.includeMinimized,
                              remember: preferences.rememberWindows, allSpaces: preferences.allSpaces,
                              startingAtFocusedWindow: selection.isWindowOnly) { [weak self] incoming, preferred, isFinal in
            guard let self else { return }
            // Honor a release during enumeration, including queued window navigation.
            if let pending = pendingCommit, pending.token == token {
                guard isFinal else { return }
                pendingCommit = nil
                var target = Selection()
                target.begin(appCount: 1)
                target.expand()
                target.setWindows(count: incoming.count, preferredIndex: preferred)
                target.moveWindow(pending.steps)
                let window = incoming.indices.contains(target.windowIndex) ? incoming[target.windowIndex] : nil
                activate(window, application: pending.application, remember: pending.remember)
                return
            }
            guard selection.isActive, generation == token,
                  apps[selection.appIndex].pid == app.pid else { return }
            if loadedPID == app.pid {
                // Keep the displayed order and selected identity stable during refresh.
                let refreshed = windows.compactMap { old in incoming.first { $0.identity == old.identity } } +
                    incoming.filter { item in !self.windows.contains { $0.identity == item.identity } }
                selection.refreshWindows(previous: windows.map(\.identity), updated: refreshed.map(\.identity))
                windows = refreshed
            } else {
                windows = incoming
                selection.setWindows(count: incoming.count, preferredIndex: preferred)
                selection.moveWindow(pendingWindowSteps)
                pendingWindowSteps = 0
            }
            loading = false
            refreshingWindows = !isFinal
            loadedPID = app.pid
            let remembered = incoming.indices.contains(preferred) ?
                windows.firstIndex { $0.identity == incoming[preferred].identity } : nil
            if selection.isExpanded { renderWindows(remembered: preferences.rememberWindows ? remembered : nil) }
        }
    }

    private func renderWindows(remembered: Int? = nil) {
        panel.expand(app: apps[selection.appIndex], windows: windows, selected: selection.windowIndex,
                     remembered: remembered, loading: false)
        visiblePreviews = []
        refreshPreviews()
    }

    private func moveWindow(_ offset: Int) {
        if loading { pendingWindowSteps += offset; return }
        selection.moveWindow(offset)
        panel.updateWindowSelection(selection.windowIndex)
        refreshPreviews()
    }

    private func refreshPreviews() {
        // A cached pass must not capture the same previews twice. Wait for fresh metadata.
        guard panel.isVisible, preferences.showPreviews, selection.isExpanded, !loading, !refreshingWindows else { return }
        let indices = panel.visibleWindowIndices()
        guard indices != visiblePreviews else { return }
        visiblePreviews = indices
        panel.clearPreviews(except: indices)
        let missing = indices.filter { !panel.hasPreview(at: $0) }
        guard !missing.isEmpty else {
            previews.cancel()
            panel.setPreviewStatus(nil)
            return
        }
        let token = generation
        previews.load(pid: apps[selection.appIndex].pid, windows: windows, indices: missing, status: { [weak self] message in
            guard let self, selection.isActive, selection.isExpanded, generation == token else { return }
            panel.setPreviewStatus(message)
        }) { [weak self] index, image in
            guard let self, selection.isActive, selection.isExpanded, generation == token,
                  visiblePreviews.contains(index) else { return }
            panel.setPreview(image, at: index)
        }
    }

    private func invalidateWindows() {
        generation += 1
        windows.removeAll()
        loadedPID = nil
        loading = false
        refreshingWindows = false
        pendingWindowSteps = 0
        visiblePreviews = []
        previews.cancel()
    }

    private func commit() {
        guard selection.isActive, apps.indices.contains(selection.appIndex) else { return }
        let app = apps[selection.appIndex].application
        if selection.isExpanded, loading {
            pendingCommit = PendingCommit(token: generation, application: app, steps: pendingWindowSteps,
                                          remember: preferences.rememberWindows)
            dismiss(clearPending: false)
            return
        }
        let window = selection.isExpanded && windows.indices.contains(selection.windowIndex) ? windows[selection.windowIndex] : nil
        let remember = preferences.rememberWindows
        cancel()
        activate(window, application: app, remember: remember)
    }

    private func activate(_ window: WindowItem?, application app: NSRunningApplication, remember: Bool) {
        let cancellation = ActionCancellation()
        focusCancellation = cancellation
        windowService.focus(window, application: app, remember: remember, cancellation: cancellation) { [weak self] success in
            guard !cancellation.isCancelled else { return }
            if !success { self?.onFocusFailure?() }
        }
    }

    func cancel() {
        directShortcuts.cancel()
        focusCancellation?.cancel()
        dismiss(clearPending: true)
    }

    func refreshShortcuts() {
        cancel()
        keyboard.bindings = preferences.shortcuts.activeBindings
    }

    private func dismiss(clearPending: Bool) {
        if clearPending { pendingCommit = nil }
        selection.end()
        panel.dismiss()
        invalidateWindows()
        apps.removeAll()
    }
}

private extension SwitcherKey {
    var isLeft: Bool { if case .left = self { return true }; return false }
}
