import AppKit
import UsageCore

/// The status item (plan.md "Gauge design", Menubar), drawn from a `DashboardModel` and
/// the menubar style.
///
/// - Normal: each configured provider's logo and usable 5-hour %; a click opens the
///   dropdown.
/// - Compact: the three-spoke glyph; a click expands it for 3 s, a click while
///   expanded opens the dropdown (`CompactExpander`).
///
/// The dropdown is whatever `onOpenDropdown` does (T9b's popover, anchored on
/// `anchorView`). Until it's connected, and on right-click or control-click, the T1
/// debug menu opens instead.
@MainActor
final class StatusItemController: NSObject {
    struct Actions {
        var refresh: () -> Void
        var writeTestToken: () -> Void
    }

    /// Opens the dropdown. When nil, the T1 debug menu is shown.
    var onOpenDropdown: (() -> Void)?

    var style: MenubarStyle {
        get { expander.style }
        set {
            expander.style = newValue
            render()
        }
    }

    /// The view to anchor the dropdown on.
    var anchorView: NSView? { item.button }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sourceLine = NSMenuItem(title: "Source: …", action: nil, keyEquivalent: "")
    private let tokenLine = NSMenuItem(title: "ocgo token: …", action: nil, keyEquivalent: "")
    private let testTokenLine = NSMenuItem(title: "Debug test token: …", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "Status: loading", action: nil, keyEquivalent: "")
    private let actions: Actions
    private let expander: CompactExpander
    private lazy var debugMenu = makeMenu()
    private var display = StatusDisplay()
    private var logos: [Provider: NSImage] = [:]
    private lazy var compactGlyph = StatusAssets.compactGlyph()

    init(actions: Actions, style: MenubarStyle = .normal,
         scheduler: any OneShotScheduling = TaskScheduler()) {
        self.actions = actions
        expander = CompactExpander(style: style, scheduler: scheduler)
        super.init()
        expander.onStateChange = { [weak self] in self?.render() }
        expander.onOpenDropdown = { [weak self] in self?.openDropdown() }
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()
    }

    func show(_ model: DashboardModel) {
        display.show(model)
        if let gauge = model.row(.go)?.fiveHour {
            statusLine.title = "Go 5-hour: \(gauge.known) of \(gauge.total) known"
        } else {
            statusLine.title = "Go: no data"
        }
        render()
    }

    /// No model to show: the item falls back to the compact glyph; the error is in the
    /// tooltip and the debug menu.
    func showError(_ message: String) {
        display.showError(message)
        statusLine.title = "Error: \(message)"
        render()
    }

    func setSourceDescription(_ text: String) { sourceLine.title = "Source: \(text)" }
    func setTokenDescription(_ text: String) { tokenLine.title = "ocgo token: \(text)" }
    func setTestTokenDescription(_ text: String) { testTokenLine.title = "Debug test token: \(text)" }

    private func render() {
        expander.hasEntries = !display.entries.isEmpty
        guard let button = item.button else { return }
        let image = display.image(showsProviders: expander.showsProviders,
                                  logo: { [self] in logo($0) }, glyph: compactGlyph)
        button.image = image
        button.setAccessibilityLabel(image.accessibilityDescription)
        button.toolTip = display.tooltip(for: image)
    }

    private func logo(_ provider: Provider) -> NSImage? {
        if let cached = logos[provider] { return cached }
        let image = StatusAssets.logo(provider)
        logos[provider] = image
        return image
    }

    @objc private func clicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showDebugMenu()
            return
        }
        expander.click()
    }

    private func openDropdown() {
        if let onOpenDropdown {
            onOpenDropdown()
        } else {
            showDebugMenu()
        }
    }

    /// Blocks until the menu closes.
    private func showDebugMenu() {
        guard let button = item.button else { return }
        debugMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Debug: the status item's state and a PNG of its button as drawn in the button's
    /// own appearance, over a plain menubar-like background.
    func debugSnapshot() -> (description: String, png: Data?) {
        guard let button = item.button else { return ("no button", nil) }
        button.layoutSubtreeIfNeeded()
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let description = "visible=\(item.isVisible) style=\(style) state=\(expander.state) "
            + "label=\(button.accessibilityLabel() ?? "") "
            + "image=\(button.image.map { "\($0.size) template=\($0.isTemplate)" } ?? "nil") "
            + "buttonFrame=\(button.frame) windowFrame=\(button.window.map { "\($0.frame)" } ?? "nil") "
            + "appearance=\(appearance?.rawValue ?? "?")"
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = button.bitmapImageRepForCachingDisplay(in: bounds) else { return (description, nil) }
        button.cacheDisplay(in: bounds, to: rep)
        let scale: CGFloat = 4
        let out = NSImage(size: NSSize(width: bounds.width * scale, height: bounds.height * scale))
        out.lockFocus()
        (appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: out.size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(origin: .zero, size: out.size))
        out.unlockFocus()
        let png = out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:])
        return (description, png)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for line in [sourceLine, tokenLine, statusLine, testTokenLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(item(title: "Refresh", action: #selector(refresh), key: "r"))
        menu.addItem(item(title: "Debug: Write Test Token", action: #selector(writeTestToken), key: ""))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Usage Monitor",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func item(title: String, action: Selector, key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = self
        return m
    }

    @objc private func refresh() { actions.refresh() }
    @objc private func writeTestToken() { actions.writeTestToken() }
}
