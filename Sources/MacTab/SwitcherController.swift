import AppKit
import SwitcherCore

final class SwitcherController {
    let preferences: Preferences
    let catalog = ApplicationCatalog()
    let windowService = WindowService()
    let keyboard = KeyboardInterceptor()
    let panel = SwitcherPanel()
    private let previews = PreviewService()
    private(set) var selection = Selection()
    private var apps: [ApplicationItem] = []
    private var windows: [WindowItem] = []
    private var loadedPID: pid_t?
    private var loading = false
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

    init(preferences: Preferences) {
        self.preferences = preferences
        keyboard.isSwitching = { [weak self] in self?.selection.isActive ?? false }
        keyboard.onKey = { [weak self] in self?.handle($0) }
        keyboard.onInterruption = { [weak self] in self?.cancel() }
        catalog.onActivation = { [weak self] pid in self?.windowService.observeFrontmost(pid) }
        catalog.onTermination = { [weak self] pid in self?.windowService.forget(pid) }
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
    }

    func start() -> Bool {
        let started = keyboard.start()
        if started, let app = NSWorkspace.shared.frontmostApplication {
            windowService.observeFrontmost(app.processIdentifier)
        }
        return started
    }

    func handle(_ key: SwitcherKey) {
        switch key {
        case .tab(let backwards):
            if selection.isWindowOnly { cancel() }
            if !selection.isActive {
                pendingCommit = nil
                apps = catalog.snapshot()
                selection.begin(appCount: apps.count, backwards: backwards)
                guard selection.isActive else { return }
                panel.showHints = preferences.showHints
                panel.show(apps: apps, selected: selection.appIndex)
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
        panel.show(apps: apps, selected: 0, windowsOnly: true)
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
        let token = generation
        panel.expand(app: app, windows: [], selected: 0, remembered: nil, loading: true)
        windowService.windows(for: app.pid, includeMinimized: preferences.includeMinimized,
                              remember: preferences.rememberWindows, allSpaces: preferences.allSpaces,
                              startingAtFocusedWindow: selection.isWindowOnly) { [weak self] windows, preferred in
            guard let self else { return }
            // Honor a release during enumeration, including queued window navigation.
            if let pending = pendingCommit, pending.token == token {
                pendingCommit = nil
                var target = Selection()
                target.begin(appCount: 1)
                target.expand()
                target.setWindows(count: windows.count, preferredIndex: preferred)
                target.moveWindow(pending.steps)
                let window = windows.indices.contains(target.windowIndex) ? windows[target.windowIndex] : nil
                activate(window, application: pending.application, remember: pending.remember)
                return
            }
            guard selection.isActive, generation == token,
                  apps[selection.appIndex].pid == app.pid else { return }
            self.windows = windows
            loading = false
            loadedPID = app.pid
            selection.setWindows(count: windows.count, preferredIndex: preferred)
            selection.moveWindow(pendingWindowSteps)
            pendingWindowSteps = 0
            if selection.isExpanded { renderWindows(remembered: preferences.rememberWindows ? preferred : nil) }
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
        guard preferences.showPreviews, selection.isExpanded, !loading else { return }
        let indices = panel.visibleWindowIndices()
        guard indices != visiblePreviews else { return }
        visiblePreviews = indices
        panel.clearPreviews()
        let token = generation
        previews.load(pid: apps[selection.appIndex].pid, windows: windows, indices: indices, status: { [weak self] message in
            guard let self, selection.isActive, selection.isExpanded, generation == token else { return }
            panel.setPreviewStatus(message)
        }) { [weak self] index, image in
            guard let self, selection.isActive, selection.isExpanded, generation == token else { return }
            panel.setPreview(image, at: index)
        }
    }

    private func invalidateWindows() {
        generation += 1
        windows.removeAll()
        loadedPID = nil
        loading = false
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
        windowService.focus(window, application: app, remember: remember) { [weak self] success in
            if !success { self?.onFocusFailure?() }
        }
    }

    func cancel() {
        dismiss(clearPending: true)
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
