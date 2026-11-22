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
/// `anchorView`). Right-click or control-click opens the menu (Settings, Refresh,
/// Quit), as does a click while `onOpenDropdown` isn't connected.
@MainActor
final class StatusItemController: NSObject {
    struct Actions {
        var refresh: () -> Void
        var openSettings: () -> Void
    }

    /// Opens the dropdown. When nil, the menu is shown.
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
    private let statusLine = NSMenuItem(title: "Status: loading", action: nil, keyEquivalent: "")
    private let actions: Actions
    private let expander: CompactExpander
    private lazy var menu = makeMenu()
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
        statusLine.title = Self.statusLine(for: model)
        render()
    }

    /// The menu's first line: each configured source's state, or "Not configured".
    nonisolated static func statusLine(for model: DashboardModel, timeZone: TimeZone = .current) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        let parts = SourceKind.allCases.compactMap { kind -> String? in
            let name = SetupForm.name(kind)
            switch model.sources[kind] {
            case .notConfigured: return nil
            case nil: return "\(name): waiting for the first poll"
            case .ok(let at): return "\(name): updated \(at.formatted(time))"
            case .authStopped(let e): return "\(name): stopped, \(shortReason(e, kind))"
            case .failing(let e, let since):
                return "\(name): failing since \(since.formatted(time)), \(shortReason(e, kind))"
            }
        }
        return parts.isEmpty ? "Not configured" : parts.joined(separator: " · ")
    }

    nonisolated static func shortReason(_ e: SourceError, _ kind: SourceKind) -> String {
        switch e {
        case .unauthorized: kind == .cliproxy ? "management key rejected" : "token rejected"
        case .remoteManagementDisabled: "remote management off"
        case .ipBanned: "IP banned"
        case .tlsUntrusted: "TLS certificate not trusted"
        case .timeout: "timed out"
        case .unreachable: "unreachable"
        case .http(let code): "HTTP \(code)"
        case .decoding: "unexpected response"
        }
    }

    /// No model to show: the item falls back to the compact glyph; the error is in the
    /// tooltip and the menu.
    func showError(_ message: String) {
        display.showError(message)
        statusLine.title = "Error: \(message)"
        render()
    }

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
            showMenu()
            return
        }
        expander.click()
    }

    private func openDropdown() {
        if let onOpenDropdown {
            onOpenDropdown()
        } else {
            showMenu()
        }
    }

    /// Blocks until the menu closes.
    private func showMenu() {
        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item(title: "Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item(title: "Refresh", action: #selector(refresh), key: "r"))
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
    @objc private func openSettings() { actions.openSettings() }
}
