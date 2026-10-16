import AppKit
import UniformTypeIdentifiers
import SwitcherCore

private final class ShortcutRecorder: NSButton {
    var shortcut: KeyboardShortcut? { didSet { if !recording { updateTitle() } } }
    var onChange: ((KeyboardShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginRecording() {
        if recording { stopRecording(); return }
        window?.makeFirstResponder(self)
        recording = true
        title = "Press shortcut…"
        onRecordingChanged?(true)
    }
    func stopRecording() {
        guard recording else { return }
        recording = false
        updateTitle()
        onRecordingChanged?(false)
    }
    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopRecording(); return }
        guard !event.isARepeat else { return }
        let value = KeyboardShortcut(event: event)
        guard value.validationError == nil else { NSSound.beep(); return }
        shortcut = value
        stopRecording()
        onChange?(value)
    }
    private func updateTitle() { title = shortcut?.displayName ?? "Record shortcut…" }
}

private enum ApplicationShortcutPicker {
    static func choose(in window: NSWindow, completion: @escaping (ApplicationShortcutTarget) -> Void) {
        let picker = NSOpenPanel()
        picker.title = "Choose an application"
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.beginSheetModal(for: window) { response in
            guard response == .OK, let url = picker.url else { return }
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  identifier != "com.tlh.mactab" else {
                let alert = NSAlert()
                alert.messageText = "Choose an application other than MacTab"
                alert.informativeText = "The destination must be an application with a bundle identifier."
                alert.beginSheetModal(for: window)
                return
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
            completion(ApplicationShortcutTarget(bundleIdentifier: identifier, bundlePath: url.path, name: name))
        }
    }
}

private final class ShortcutEditor: NSWindowController, NSWindowDelegate {
    private var binding: ShortcutBinding
    private let configuration: ShortcutConfiguration
    private let recorder = ShortcutRecorder()
    private let destination = NSTextField(labelWithString: "")
    private let launch = NSButton(checkboxWithTitle: "Launch if closed", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    var onSave: ((ShortcutBinding) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    init(binding: ShortcutBinding, configuration: ShortcutConfiguration) {
        self.binding = binding
        self.configuration = configuration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Shortcut destination"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = window.contentView!
        func label(_ title: String, y: CGFloat) {
            let field = NSTextField(labelWithString: title)
            field.frame = NSRect(x: 24, y: y, width: 190, height: 22)
            content.addSubview(field)
        }
        label("MacTab shortcut", y: 251)
        recorder.frame = NSRect(x: 218, y: 245, width: 210, height: 32)
        recorder.shortcut = binding.shortcut
        recorder.onChange = { [weak self] value in self?.binding.shortcut = value; self?.validate() }
        content.addSubview(recorder)
        destination.frame = NSRect(x: 24, y: 298, width: 500, height: 22)
        destination.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addSubview(destination)

        switch binding.target {
        case .application(let app):
            destination.stringValue = app.name
            launch.frame = NSRect(x: 24, y: 204, width: 190, height: 24)
            launch.state = app.launchIfClosed ? .on : .off
            content.addSubview(launch)
            let choose = NSButton(title: "Choose application…", target: self, action: #selector(chooseApplication))
            choose.frame = NSRect(x: 215, y: 200, width: 210, height: 32)
            content.addSubview(choose)
            let explanation = NSTextField(wrappingLabelWithString: "Activate this app from another app. Press again while it is active to cycle its windows. Uses your window and remembering preferences.")
            explanation.frame = NSRect(x: 24, y: 119, width: 512, height: 65)
            explanation.textColor = .secondaryLabelColor
            content.addSubview(explanation)
        }
        recorder.onRecordingChanged = { [weak self] active in self?.onRecordingChanged?(active) }
        errorLabel.frame = NSRect(x: 24, y: 45, width: 512, height: 40)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .secondaryLabelColor
        content.addSubview(errorLabel)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        cancel.frame = NSRect(x: 350, y: 10, width: 90, height: 30)
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        saveButton.frame = NSRect(x: 446, y: 10, width: 90, height: 30)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)
        validate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updatedBinding() -> ShortcutBinding {
        var result = binding
        switch binding.target {
        case .application(var app):
            app.launchIfClosed = launch.state == .on
            result.target = .application(app)
        }
        return result
    }
    private func validate() {
        let message = configuration.validationError(for: updatedBinding())
        errorLabel.stringValue = message ?? "Use Command, Control, or Option. Escape cancels recording. System and other app shortcuts may conflict."
        saveButton.isEnabled = message == nil
    }
    @objc private func chooseApplication() {
        guard let window else { return }
        recorder.stopRecording()
        ApplicationShortcutPicker.choose(in: window) { [weak self] target in
            guard let self else { return }
            binding.target = .application(target)
            destination.stringValue = target.name
            validate()
        }
    }
    @objc private func save() {
        let result = updatedBinding()
        guard configuration.validationError(for: result) == nil else { return }
        recorder.stopRecording()
        onSave?(result)
        cancelEditing()
    }
    @objc private func cancelEditing() {
        recorder.stopRecording()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        close()
    }
    func windowDidResignKey(_ notification: Notification) {
        recorder.stopRecording()
    }
    func windowDidBecomeKey(_ notification: Notification) { validate() }
}

final class ShortcutSettingsWindow: NSWindowController, NSWindowDelegate {
    private let preferences: Preferences
    private let scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var configuration: ShortcutConfiguration
    private var editor: ShortcutEditor?
    var onChange: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        configuration = preferences.shortcuts
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MacTab Shortcuts"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        let content = window.contentView!
        let intro = NSTextField(wrappingLabelWithString: "Go straight to an app. Press its shortcut while the app is active to cycle its windows.")
        intro.frame = NSRect(x: 24, y: 398, width: 672, height: 38)
        content.addSubview(intro)
        let addApp = NSButton(title: "Add application…", target: self, action: #selector(addApplication))
        addApp.frame = NSRect(x: 20, y: 351, width: 158, height: 32)
        content.addSubview(addApp)
        scroll.frame = NSRect(x: 24, y: 102, width: 672, height: 238)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        status.frame = NSRect(x: 24, y: 63, width: 672, height: 32)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        content.addSubview(status)
        let help = NSTextField(wrappingLabelWithString: "Use macOS Keyboard Shortcuts → Mission Control for desktop shortcuts. MacTab focuses on apps and their windows.")
        help.frame = NSRect(x: 24, y: 14, width: 672, height: 43)
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 11)
        content.addSubview(help)
        reloadRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        configuration = preferences.shortcuts
        reloadRows()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    private func reloadRows() {
        let rows = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: max(238, CGFloat(configuration.bindings.count) * 52)))
        for (index, binding) in configuration.bindings.enumerated() {
            let y = rows.frame.height - CGFloat(index + 1) * 52
            let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleBinding(_:)))
            toggle.frame = NSRect(x: 0, y: y + 16, width: 24, height: 24)
            toggle.state = binding.enabled ? .on : .off
            toggle.tag = index
            rows.addSubview(toggle)
            let name: String
            let detail: String
            switch binding.target {
            case .application(let app): name = app.name; detail = app.launchIfClosed ? "Activate / cycle · Launch if closed" : "Activate / cycle"
            }
            toggle.setAccessibilityLabel("Enable \(name) shortcut")
            let title = NSTextField(labelWithString: name)
            title.frame = NSRect(x: 32, y: y + 27, width: 230, height: 19)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            rows.addSubview(title)
            let subtitle = NSTextField(labelWithString: detail)
            subtitle.frame = NSRect(x: 32, y: y + 6, width: 290, height: 18)
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            rows.addSubview(subtitle)
            let chord = NSTextField(labelWithString: binding.shortcut?.displayName ?? "Not assigned")
            chord.frame = NSRect(x: 330, y: y + 18, width: 150, height: 22)
            rows.addSubview(chord)
            let edit = NSButton(title: "Edit…", target: self, action: #selector(editBinding(_:)))
            edit.frame = NSRect(x: 478, y: y + 12, width: 80, height: 32)
            edit.tag = index
            rows.addSubview(edit)
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeBinding(_:)))
            remove.frame = NSRect(x: 560, y: y + 12, width: 88, height: 32)
            remove.tag = index
            rows.addSubview(remove)
        }
        if configuration.bindings.isEmpty {
            let empty = NSTextField(labelWithString: "No shortcuts yet. Add an application above.")
            empty.frame = NSRect(x: 10, y: 178, width: 600, height: 30)
            empty.textColor = .secondaryLabelColor
            rows.addSubview(empty)
        }
        scroll.documentView = rows
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rows.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        status.stringValue = configuration.version == 1 ? "Changes are saved automatically. No shortcuts are enabled until you add one." : "This shortcut configuration is from a newer version. Editing will replace it."
    }
    private func persist() {
        configuration.version = 1
        preferences.shortcuts = configuration
        reloadRows()
        onChange?()
    }
    @objc private func addApplication() {
        guard let window else { return }
        ApplicationShortcutPicker.choose(in: window) { [weak self] target in
            self?.edit(ShortcutBinding(target: .application(target)))
        }
    }
    @objc private func editBinding(_ sender: NSButton) {
        guard configuration.bindings.indices.contains(sender.tag) else { return }
        edit(configuration.bindings[sender.tag])
    }
    private func edit(_ binding: ShortcutBinding) {
        guard let window, editor == nil else { return }
        let editor = ShortcutEditor(binding: binding, configuration: configuration)
        self.editor = editor
        editor.onRecordingChanged = { [weak self] in self?.onRecordingChanged?($0) }
        editor.onSave = { [weak self] binding in
            guard let self else { return }
            if let index = configuration.bindings.firstIndex(where: { $0.id == binding.id }) { configuration.bindings[index] = binding }
            else { configuration.bindings.append(binding) }
            persist()
        }
        // AppKit queues this sheet if the application picker is still ending.
        window.beginSheet(editor.window!) { [weak self] _ in
            self?.onRecordingChanged?(false)
            self?.editor = nil
        }
    }
    @objc private func toggleBinding(_ sender: NSButton) {
        guard configuration.bindings.indices.contains(sender.tag) else { return }
        var binding = configuration.bindings[sender.tag]
        binding.enabled = sender.state == .on
        if binding.enabled, let message = configuration.validationError(for: binding) {
            sender.state = .off
            status.stringValue = message
            return
        }
        configuration.bindings[sender.tag] = binding
        persist()
    }
    @objc private func removeBinding(_ sender: NSButton) {
        guard configuration.bindings.indices.contains(sender.tag) else { return }
        configuration.bindings.remove(at: sender.tag)
        persist()
    }
    func windowWillClose(_ notification: Notification) {
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        editor?.close()
        editor = nil
        onRecordingChanged?(false)
    }
}
