import AppKit
import QuartzCore
import SwitcherCore

private final class TileButton: NSButton {
    enum Content {
        case application(ApplicationItem)
        case window(WindowItem, NSImage, Bool)
    }
    let content: Content
    // Core Animation stores every CATransition under this key, regardless of the supplied key.
    private static let previewFadeKey = kCATransition
    var chosen = false {
        didSet {
            guard chosen != oldValue else { return }
            // Keyboard selection stays immediate, even during a preview transition.
            layer?.removeAnimation(forKey: Self.previewFadeKey)
            needsDisplay = true
        }
    }
    var preview: NSImage? {
        willSet {
            guard newValue !== preview else { return }
            layer?.removeAnimation(forKey: Self.previewFadeKey)
            guard newValue != nil, window?.isVisible == true,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Core Animation blends the existing backing contents; no redraw timer
            // or second NSImage is retained by the app for the transition.
            layer?.add(fade, forKey: Self.previewFadeKey)
        }
        didSet { if preview !== oldValue { needsDisplay = true } }
    }
    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    init(content: Content, size: NSSize) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: size))
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        switch content {
        case .application(let app): setAccessibilityLabel(app.name)
        case .window(let window, _, _):
            wantsLayer = true
            setAccessibilityLabel("\(window.title), \(window.displayName)")
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let area: NSRect
        switch content {
        case .application:
            let side = max(1, bounds.width * 112 / 120)
            area = NSRect(x: (bounds.width - side) / 2, y: 24, width: side, height: side)
        case .window:
            area = bounds.insetBy(dx: 3, dy: 3)
        }
        if chosen {
            NSColor.white.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: area, xRadius: 22, yRadius: 22).fill()
        }
        switch content {
        case .application(let app):
            let iconSize = min(96, bounds.width * 96 / 120)
            app.icon.draw(in: NSRect(x: (bounds.width - iconSize) / 2, y: area.midY - iconSize / 2, width: iconSize, height: iconSize))
            if chosen {
                text(app.name, rect: NSRect(x: 4, y: 3, width: bounds.width - 8, height: 18),
                     font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
            }
        case .window(let window, let icon, let remembered):
            let imageRect = NSRect(x: 12, y: 49, width: bounds.width - 24, height: bounds.height - 90)
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: 7, yRadius: 7).fill()
            if let preview {
                let ratio = min(imageRect.width / max(preview.size.width, 1), imageRect.height / max(preview.size.height, 1))
                let size = NSSize(width: preview.size.width * ratio, height: preview.size.height * ratio)
                preview.draw(in: NSRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2, width: size.width, height: size.height))
            } else {
                icon.draw(in: NSRect(x: imageRect.midX - 22, y: imageRect.midY - 22, width: 44, height: 44))
            }
            text(window.title, rect: NSRect(x: 12, y: bounds.height - 32, width: bounds.width - 24, height: 18),
                 font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
            text(window.displayName + (window.isOnCurrentSpace ? "" : " · Other Space") + (window.isMinimized ? " · Minimized" : ""),
                 rect: NSRect(x: 12, y: 22, width: bounds.width - 24, height: 16),
                 font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
            if remembered {
                text("LAST USED", rect: NSRect(x: imageRect.maxX - 74, y: imageRect.minY + 5, width: 68, height: 14),
                     font: .systemFont(ofSize: 8, weight: .semibold), color: .secondaryLabelColor)
            }
        }
    }

    private func text(_ value: String, rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

final class SwitcherPanel: NSPanel {
    private let surface = NSView()
    private var glass: NSView!
    private let appScroll = NSScrollView()
    private let windowScroll = NSScrollView()
    private let separator = NSBox()
    private let hint = NSTextField(labelWithString: "")
    private let windowHeading = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var appTiles: [TileButton] = []
    private var windowTiles: [TileButton] = []
    private var screenFrame = NSRect.zero
    private var scrollObserver: NSObjectProtocol?
    private var windowsOnly = false
    private var appTileWidth: CGFloat = 120
    private var appTileHeight: CGFloat { appTileWidth * 112 / 120 + 28 }
    private var headingText = ""
    var showHints = true
    private var footerHeight: CGFloat { showHints ? 28 : 0 }
    private var collapsedHeight: CGFloat { appTileHeight + 26 + footerHeight }
    private var expandedHeight: CGFloat { (windowsOnly ? 234 : appTileHeight + 256) + footerHeight }
    var onAppClick: ((Int) -> Void)?
    var onWindowClick: ((Int) -> Void)?
    var onVisibleWindowsChanged: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        // Keep the floating switcher legible over both white and dark windows.
        appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular
            effect.cornerRadius = 32
            effect.contentView = surface
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 32
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 1
            effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            effect.addSubview(surface)
            glass = effect
        }
        contentView = glass
        for scroll in [appScroll, windowScroll] {
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.horizontalScrollElasticity = .none
            scroll.verticalScrollElasticity = .none
            surface.addSubview(scroll)
        }
        appScroll.hasHorizontalScroller = false
        separator.boxType = .separator
        surface.addSubview(separator)
        for label in [hint, windowHeading, emptyLabel] {
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
            surface.addSubview(label)
        }
        windowHeading.font = .systemFont(ofSize: 12, weight: .medium)
        windowHeading.textColor = .labelColor
        windowScroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: windowScroll.contentView, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.onVisibleWindowsChanged?() }
        }
    }

    func show(apps: [ApplicationItem], selected: Int, windowsOnly: Bool = false) {
        self.windowsOnly = windowsOnly
        let point = NSEvent.mouseLocation
        screenFrame = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let appLayout = AppRowLayout(appCount: apps.count, screenWidth: screenFrame.width)
        let width = windowsOnly ? min(760, screenFrame.width - 48) : appLayout.width
        appTileWidth = appLayout.tileWidth
        appScroll.isHidden = windowsOnly
        appTiles = (windowsOnly ? [] : apps).enumerated().map { index, app in
            let tile = TileButton(content: .application(app), size: NSSize(width: appTileWidth, height: appTileHeight))
            tile.tag = index
            tile.target = self
            tile.action = #selector(appClicked(_:))
            return tile
        }
        appScroll.documentView = row(appTiles, tileWidth: appTileWidth, height: appTileHeight)
        setFrame(NSRect(x: screenFrame.midX - width / 2, y: screenFrame.midY - 90, width: width, height: collapsedHeight), display: false)
        updateAppSelection(selected)
        if !windowsOnly { collapse() }
        else { layoutContents() }
        updateAppSelection(selected)
        orderFrontRegardless()
    }

    private func row(_ tiles: [TileButton], tileWidth: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: max(CGFloat(tiles.count) * tileWidth, 1), height: height))
        for (index, tile) in tiles.enumerated() {
            tile.frame.origin = NSPoint(x: CGFloat(index) * tileWidth, y: 0)
            view.addSubview(tile)
        }
        return view
    }

    func updateAppSelection(_ selected: Int) {
        for (index, tile) in appTiles.enumerated() { tile.chosen = index == selected }
        if appTiles.indices.contains(selected) { appTiles[selected].scrollToVisible(appTiles[selected].bounds) }
    }

    func expand(app: ApplicationItem, windows: [WindowItem], selected: Int, remembered: Int?, loading: Bool) {
        resize(height: expandedHeight)
        windowScroll.isHidden = false
        separator.isHidden = windowsOnly
        windowHeading.isHidden = false
        headingText = "\(app.name) · \(loading ? "Windows" : String(windows.count) + (windows.count == 1 ? " window" : " windows"))"
        windowHeading.stringValue = headingText
        hint.stringValue = "⌘ `  Next window     ⇧  Reverse     ← →  Select     Release ⌘ to switch"
        emptyLabel.isHidden = !windows.isEmpty
        emptyLabel.stringValue = loading ? "Finding windows…" : "No accessible windows"
        windowTiles = windows.enumerated().map { index, window in
            let tile = TileButton(content: .window(window, app.icon, index == remembered), size: NSSize(width: 236, height: 186))
            tile.tag = index
            tile.target = self
            tile.action = #selector(windowClicked(_:))
            return tile
        }
        windowScroll.documentView = row(windowTiles, tileWidth: 236, height: 186)
        updateWindowSelection(selected)
        layoutContents()
    }

    func updateWindowSelection(_ selected: Int) {
        for (index, tile) in windowTiles.enumerated() { tile.chosen = index == selected }
        if windowTiles.indices.contains(selected) { windowTiles[selected].scrollToVisible(windowTiles[selected].bounds) }
    }

    func visibleWindowIndices() -> [Int] {
        guard let document = windowScroll.documentView else { return [] }
        let visible = document.visibleRect
        return windowTiles.indices.filter { windowTiles[$0].frame.intersects(visible) }.prefix(6).map { $0 }
    }

    func clearPreviews(except indices: [Int] = []) {
        for (index, tile) in windowTiles.enumerated() where !indices.contains(index) { tile.preview = nil }
    }
    func hasPreview(at index: Int) -> Bool {
        windowTiles.indices.contains(index) && windowTiles[index].preview != nil
    }
    func setPreviewStatus(_ message: String?) {
        windowHeading.stringValue = headingText + (message.map { " · " + $0 } ?? "")
    }
    func dismiss() {
        orderOut(nil)
        appTiles.removeAll()
        windowTiles.removeAll()
        appScroll.documentView = nil
        windowScroll.documentView = nil
        windowsOnly = false
    }
    func setPreview(_ image: NSImage, at index: Int) {
        guard windowTiles.indices.contains(index) else { return }
        windowTiles[index].preview = image
    }

    func collapse() {
        resize(height: collapsedHeight)
        windowScroll.isHidden = true
        separator.isHidden = true
        windowHeading.isHidden = true
        emptyLabel.isHidden = true
        windowTiles.removeAll()
        windowScroll.documentView = nil
        hint.stringValue = "⌘ Tab  Next app     ⌘ `  Show windows     Release ⌘ to switch"
        layoutContents()
    }

    private func resize(height: CGFloat) {
        // Keep the app row fixed while the window row opens beneath it.
        let top = screenFrame.midY + 90
        setFrame(NSRect(x: frame.minX, y: max(screenFrame.minY + 12, top - height), width: frame.width, height: height), display: true)
        layoutContents()
    }

    private func layoutContents() {
        glass.frame = NSRect(origin: .zero, size: frame.size)
        surface.frame = glass.bounds
        let width = frame.width
        let height = frame.height
        appScroll.frame = NSRect(x: 16, y: height - appTileHeight - 20, width: width - 32, height: appTileHeight + 4)
        hint.frame = NSRect(x: 12, y: 12, width: width - 24, height: 16)
        hint.isHidden = !showHints
        separator.frame = NSRect(x: 24, y: height - appTileHeight - 34, width: width - 48, height: 1)
        windowHeading.frame = NSRect(x: 24, y: height - (windowsOnly ? 32 : appTileHeight + 61), width: width - 48, height: 18)
        windowScroll.frame = NSRect(x: 16, y: 12 + footerHeight, width: width - 32, height: 186)
        emptyLabel.frame = NSRect(x: 24, y: 92 + footerHeight, width: width - 48, height: 20)
        if let document = appScroll.documentView, document.frame.width < appScroll.frame.width {
            let inset = (appScroll.frame.width - CGFloat(appTiles.count) * appTileWidth) / 2
            document.setFrameSize(NSSize(width: appScroll.frame.width, height: appTileHeight))
            for (index, tile) in appTiles.enumerated() { tile.frame.origin.x = inset + CGFloat(index) * appTileWidth }
        }
        if let document = windowScroll.documentView, CGFloat(windowTiles.count) * 236 < windowScroll.frame.width {
            let inset = (windowScroll.frame.width - CGFloat(windowTiles.count) * 236) / 2
            document.setFrameSize(NSSize(width: windowScroll.frame.width, height: 186))
            for (index, tile) in windowTiles.enumerated() { tile.frame.origin.x = inset + CGFloat(index) * 236 }
        }
    }

    @objc private func appClicked(_ sender: NSButton) { onAppClick?(sender.tag) }
    @objc private func windowClicked(_ sender: NSButton) { onWindowClick?(sender.tag) }

    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
}
