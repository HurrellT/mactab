import AppKit
import ApplicationServices
import SwitcherCore

final class SettingsWindow: NSWindowController {
    private let preferences: Preferences
    private let status = NSTextField(labelWithString: "")
    private let previewStatus = NSTextField(labelWithString: "")
    private let remember = NSButton(checkboxWithTitle: "Remember the last focused window of each app", target: nil, action: nil)
    private let minimized = NSButton(checkboxWithTitle: "Include minimized windows", target: nil, action: nil)
    private let previews = NSButton(checkboxWithTitle: "Show window thumbnails when expanded", target: nil, action: nil)
    private let allSpaces = NSButton(checkboxWithTitle: "Show windows from all Spaces", target: nil, action: nil)
    private let hints = NSButton(checkboxWithTitle: "Show keyboard hints in the switcher", target: nil, action: nil)
    var onRefresh: ((Bool) -> PermissionReport?)?
    var onRelaunch: (() -> Void)?
    var onPreferencesChanged: (() -> Void)?
    var onOpenShortcuts: (() -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 610),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MacTab"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 610))
        window.contentView = content

        let brand = label("MACTAB", size: 11, weight: .bold, color: .secondaryLabelColor)
        brand.frame = NSRect(x: 32, y: 554, width: 470, height: 20)
        let title = label("Your apps. Your windows.", size: 27, weight: .semibold)
        title.frame = NSRect(x: 30, y: 512, width: 480, height: 36)
        let intro = label("A small, native upgrade to switching on your Mac.", size: 13, color: .secondaryLabelColor)
        intro.frame = NSRect(x: 32, y: 483, width: 470, height: 22)
        [brand, title, intro].forEach(content.addSubview)

        let instructions = label("Hold ⌘ Tab to choose an app, then ` to reveal its windows.\nOr hold ⌘ ` directly for the current app’s windows.\nPress ` again or use ← → to choose. Release ⌘ to switch.", size: 13)
        instructions.maximumNumberOfLines = 3
        instructions.frame = NSRect(x: 32, y: 394, width: 476, height: 72)
        content.addSubview(instructions)

        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(x: 32, y: 381, width: 476, height: 1)
        content.addSubview(divider)

        for (index, button) in [remember, minimized, allSpaces, hints, previews].enumerated() {
            button.frame = NSRect(x: 32, y: 337 - index * 31, width: 476, height: 24)
            button.target = self
            button.action = #selector(preferenceChanged(_:))
            content.addSubview(button)
        }
        remember.state = preferences.rememberWindows ? .on : .off
        minimized.state = preferences.includeMinimized ? .on : .off
        previews.state = preferences.showPreviews ? .on : .off
        allSpaces.state = preferences.allSpaces ? .on : .off
        allSpaces.toolTip = "Turn off to show only windows on the currently displayed Spaces."
        hints.state = preferences.showHints ? .on : .off

        previewStatus.font = .systemFont(ofSize: 11)
        previewStatus.textColor = .secondaryLabelColor
        previewStatus.frame = NSRect(x: 51, y: 179, width: 455, height: 28)
        previewStatus.maximumNumberOfLines = 2
        previewStatus.lineBreakMode = .byWordWrapping
        content.addSubview(previewStatus)

        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.frame = NSRect(x: 32, y: 123, width: 476, height: 38)
        content.addSubview(status)
        let grant = NSButton(title: "Enable Accessibility…", target: self, action: #selector(grantAccessibility))
        grant.frame = NSRect(x: 28, y: 79, width: 190, height: 32)
        content.addSubview(grant)
        let refresh = NSButton(title: "Check permissions", target: self, action: #selector(refreshPermissions))
        refresh.frame = NSRect(x: 222, y: 79, width: 160, height: 32)
        content.addSubview(refresh)
        let relaunch = NSButton(title: "Relaunch", target: self, action: #selector(relaunchApp))
        relaunch.frame = NSRect(x: 389, y: 79, width: 122, height: 32)
        content.addSubview(relaunch)
        let footnote = label("Runs in the menu bar. No background window scanning or recording.", size: 11, color: .secondaryLabelColor)
        footnote.frame = NSRect(x: 166, y: 29, width: 342, height: 30)
        footnote.maximumNumberOfLines = 2
        content.addSubview(footnote)
        let shortcuts = NSButton(title: "Shortcuts…", target: self, action: #selector(openShortcuts))
        shortcuts.frame = NSRect(x: 28, y: 27, width: 125, height: 32)
        content.addSubview(shortcuts)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshStatus(report: PermissionReport? = nil) {
        guard let report = report ?? onRefresh?(false) else { return }
        status.textColor = report.availability == .ready ? .systemGreen : .secondaryLabelColor
        switch report.availability {
        case .ready:
            status.stringValue = "Ready · Accessibility granted and keyboard interception active."
        case .accessibilityRequired:
            status.stringValue = "macOS has not granted Accessibility to this MacTab build.\nAlready enabled? Check permissions for repair steps."
        case .keyboardUnavailable:
            status.stringValue = "Accessibility is granted, but keyboard interception failed.\nCheck permissions for the next step."
        case .secureInput:
            status.stringValue = "Secure Keyboard Entry is blocking keyboard interception.\nClose password prompts, then check permissions again."
        case .paused:
            status.stringValue = "Paused · enable MacTab from its menu bar menu."
        case .demo:
            status.stringValue = "UI demo · shortcuts are not intercepted in this mode."
        }
        previewStatus.stringValue = CGPreflightScreenCaptureAccess()
            ? "Screen Recording: granted. Thumbnails are captured only while switching."
            : "Screen Recording is not granted to this build.\nCheck permissions for repair steps."
    }

    @objc private func preferenceChanged(_ sender: NSButton) {
        preferences.rememberWindows = remember.state == .on
        preferences.includeMinimized = minimized.state == .on
        preferences.showPreviews = previews.state == .on
        preferences.allSpaces = allSpaces.state == .on
        preferences.showHints = hints.state == .on
        if sender === previews, previews.state == .on, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        onPreferencesChanged?()
        refreshStatus()
    }

    @objc private func grantAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshPermissions() {
        guard let report = onRefresh?(true), let window else { return }
        refreshStatus(report: report)
        let alert = NSAlert()
        var settingsPane: String?
        switch report.availability {
        case .ready:
            alert.messageText = "MacTab is ready"
            alert.informativeText = "Accessibility: granted\nKeyboard interception: active\n\nHold Command and press Tab to choose an app, then ` to show its windows. Use Command + ` directly for the current app’s windows."
            if preferences.showPreviews, !CGPreflightScreenCaptureAccess() {
                alert.messageText = "Window switching is ready; thumbnails need permission"
                settingsPane = "Privacy_ScreenCapture"
            }
        case .accessibilityRequired:
            alert.messageText = "Accessibility is not granted to this build"
            alert.informativeText = "macOS reports that this running copy of MacTab is not trusted.\n\nIf MacTab already appears enabled, remove its old entry with −, add this app again with +, and enable it. A rebuilt local app can have a different signature. Then use Relaunch.\n\nCurrent app:\n\(Bundle.main.bundleURL.path)"
            settingsPane = "Privacy_Accessibility"
        case .keyboardUnavailable:
            alert.messageText = "Keyboard interception could not start"
            alert.informativeText = report.inputMonitoringGranted
                ? "Accessibility is granted, but macOS did not enable the keyboard hook. Relaunch MacTab and check again."
                : "Accessibility is granted, but the keyboard hook could not start and Input Monitoring is not granted. Enable MacTab under Privacy & Security → Input Monitoring, then relaunch."
            if !report.inputMonitoringGranted { settingsPane = "Privacy_ListenEvent" }
        case .secureInput:
            alert.messageText = "Secure Keyboard Entry is active"
            alert.informativeText = "macOS is protecting keyboard input. Close password prompts, or check whether Secure Keyboard Entry is enabled in Terminal or iTerm. Check permissions again once it is inactive."
        case .paused:
            alert.messageText = "MacTab is paused"
            alert.informativeText = "Choose Enable MacTab from its menu bar menu to resume shortcut handling."
        case .demo:
            alert.messageText = "MacTab is running as a UI demo"
            alert.informativeText = "Demo mode shows the interface without intercepting shortcuts. Relaunch to start the normal app."
        }
        if CGPreflightScreenCaptureAccess() {
            alert.informativeText += "\n\nScreen Recording: granted to this build."
        } else {
            alert.informativeText += "\n\nScreen Recording: not granted to this build. If MacTab already appears enabled under Screen & System Audio Recording, remove the old entry, add this app again, and use Relaunch. Screen Recording grants can also become stale after ad-hoc-signed rebuilds.\n\nCurrent app:\n\(Bundle.main.bundleURL.path)"
        }
        alert.alertStyle = report.availability == .ready ? .informational : .warning
        if let settingsPane {
            let title = settingsPane == "Privacy_Accessibility" ? "Open Accessibility…"
                : settingsPane == "Privacy_ScreenCapture" ? "Open Screen Recording…" : "Open Input Monitoring…"
            alert.addButton(withTitle: title)
            alert.addButton(withTitle: "Relaunch MacTab")
            alert.addButton(withTitle: "Cancel")
        } else if report.availability != .ready {
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Relaunch MacTab")
        } else {
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn, let settingsPane,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") {
                NSWorkspace.shared.open(url)
            } else if response == .alertSecondButtonReturn { self?.onRelaunch?() }
        }
    }

    @objc private func relaunchApp() { onRelaunch?() }
    @objc private func openShortcuts() { onOpenShortcuts?() }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
}
