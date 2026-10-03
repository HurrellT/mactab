import AppKit
import Carbon
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private var switcher: SwitcherController!
    private var settings: SettingsWindow!
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var enabled = true
    private var demoPanel: SwitcherPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--diagnostics") {
            printDiagnostics()
            NSApp.terminate(nil)
            return
        }
        switcher = SwitcherController(preferences: preferences)
        settings = SettingsWindow(preferences: preferences)
        settings.onRefresh = { [weak self] restart in self?.permissionReport(restart: restart) }
        settings.onRelaunch = { [weak self] in self?.relaunch() }
        settings.onPreferencesChanged = { [weak self] in self?.switcher.cancel() }
        switcher.onFocusFailure = { NSSound.beep() }
        setupMenu()
        if isDemo {
            showDemo(expanded: CommandLine.arguments.contains("--demo-expanded") || CommandLine.arguments.contains("--demo-windows"))
        } else if !refreshKeyboard() || CommandLine.arguments.contains("--settings") {
            settings.present()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard settings != nil, !isDemo else { return }
        settings.refreshStatus(report: permissionReport())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.present()
        return true
    }

    private var isDemo: Bool {
        ["--demo", "--demo-expanded", "--demo-windows"].contains { CommandLine.arguments.contains($0) }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "MacTab")
        let menu = NSMenu()
        let name = NSMenuItem(title: "MacTab", action: nil, keyEquivalent: "")
        name.isEnabled = false
        menu.addItem(name)
        menu.addItem(.separator())
        enabledItem = NSMenuItem(title: "Enable MacTab", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacTab", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refreshKeyboard() -> Bool {
        guard enabled, !isDemo else { return false }
        if !AXIsProcessTrusted() { switcher.keyboard.stop(); return false }
        return switcher.start()
    }

    private func permissionReport(restart: Bool = false) -> PermissionReport {
        if restart { switcher.keyboard.stop() }
        let running = refreshKeyboard()
        return PermissionReport(accessibilityGranted: AXIsProcessTrusted(), keyboardRunning: running,
                                inputMonitoringGranted: CGPreflightListenEventAccess(),
                                secureInputEnabled: IsSecureEventInputEnabled(), enabled: enabled, demo: isDemo)
    }

    private func printDiagnostics() {
        let keyboard = KeyboardInterceptor()
        let running = keyboard.start()
        let result: [String: Any] = [
            "appPath": Bundle.main.bundleURL.path,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "accessibilityGranted": AXIsProcessTrusted(),
            "inputMonitoringGranted": CGPreflightListenEventAccess(),
            "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
            "eventTapEnabled": running,
            "crossSpaceRecoveryAvailable": CrossSpaceAccessibility().isAvailable,
            "secureInputEnabled": IsSecureEventInputEnabled()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print(json) }
        keyboard.stop()
    }

    private func relaunch() {
        switcher.keyboard.stop()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--settings"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                if application != nil { NSApp.terminate(nil) }
                else {
                    let alert = NSAlert()
                    alert.messageText = "MacTab could not relaunch"
                    alert.informativeText = error?.localizedDescription ?? "Open build/MacTab.app again."
                    alert.runModal()
                    self?.settings.refreshStatus()
                }
            }
        }
    }

    @objc private func openSettings() { settings.present() }
    @objc private func toggleEnabled() {
        enabled.toggle()
        enabledItem.state = enabled ? .on : .off
        if enabled { if !refreshKeyboard() { settings.present() } }
        else { switcher.keyboard.stop() }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        switcher?.keyboard.stop()
    }

    private func showDemo(expanded: Bool) {
        let names = ["Safari", "Google Chrome", "Finder", "Terminal", "Notes"]
        var apps = names.compactMap { name -> ApplicationItem? in
            let paths = ["/Applications/\(name).app", "/System/Applications/\(name).app", "/System/Library/CoreServices/\(name).app", "/System/Applications/Utilities/\(name).app"]
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
            let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == name } ?? NSRunningApplication.current
            return ApplicationItem(application: app, icon: NSWorkspace.shared.icon(forFile: path), displayName: name)
        }
        if CommandLine.arguments.contains("--many-apps"), !apps.isEmpty {
            let samples = apps
            apps = (0..<30).map { samples[$0 % samples.count] }
        }
        guard !apps.isEmpty else { return }
        let panel = SwitcherPanel()
        panel.showHints = preferences.showHints && !CommandLine.arguments.contains("--hide-hints")
        demoPanel = panel
        let index = min(1, apps.count - 1)
        panel.show(apps: apps, selected: index, windowsOnly: CommandLine.arguments.contains("--demo-windows"))
        if expanded {
            let titles = ["Project workspace", "Research & documentation", "Personal"]
            let windows = titles.enumerated().map { offset, title in
                WindowItem(element: AXUIElementCreateApplication(getpid()), title: title,
                           frame: CGRect(x: 0, y: 0, width: 1200, height: 800), isMinimized: false,
                           displayName: "Display \(offset == 2 ? 1 : 2)")
            }
            panel.expand(app: apps[index], windows: windows, selected: 1, remembered: 1, loading: false)
        }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
