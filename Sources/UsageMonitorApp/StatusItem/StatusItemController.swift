import AppKit
import UsageCore

/// T1's bare status item: the Go logo as a template image and the pooled 5-hour %.
/// T9a replaces it with the drawn Normal/Compact item; T9b with the popover.
@MainActor
final class StatusItemController: NSObject {
    struct Actions {
        var refresh: () -> Void
        var writeTestToken: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sourceLine = NSMenuItem(title: "Source: …", action: nil, keyEquivalent: "")
    private let tokenLine = NSMenuItem(title: "ocgo token: …", action: nil, keyEquivalent: "")
    private let testTokenLine = NSMenuItem(title: "Debug test token: …", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "Status: loading", action: nil, keyEquivalent: "")
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        super.init()
        if let button = item.button {
            button.image = Self.logo(named: "opencode")
            button.imagePosition = .imageLeft
            button.title = "--"
            button.toolTip = "Usage Monitor"
        }
        item.menu = makeMenu()
    }

    func show(_ model: DashboardModel) {
        let gauge = model.row(.go)?.fiveHour
        item.button?.title = StatusText.title(for: gauge)
        if let gauge {
            statusLine.title = "Go 5-hour: \(gauge.known) of \(gauge.total) known"
        } else {
            statusLine.title = "Go: no data"
        }
    }

    func showError(_ message: String) {
        item.button?.title = "--"
        statusLine.title = "Error: \(message)"
    }

    func setSourceDescription(_ text: String) { sourceLine.title = "Source: \(text)" }
    func setTokenDescription(_ text: String) { tokenLine.title = "ocgo token: \(text)" }
    func setTestTokenDescription(_ text: String) { testTokenLine.title = "Debug test token: \(text)" }

    /// Debug: the status item's state and a PNG of its button as drawn in the button's
    /// own appearance, over a plain menubar-like background.
    func debugSnapshot() -> (description: String, png: Data?) {
        guard let button = item.button else { return ("no button", nil) }
        button.layoutSubtreeIfNeeded()
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let description = "visible=\(item.isVisible) title=\(button.title) "
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

    /// Loads a white-on-transparent SVG logo from the bundle as a 14 px template image.
    /// Falls back to the repo's assets/ when run outside the .app.
    static func logo(named name: String) -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "svg"),
            URL(fileURLWithPath: "assets/logos/\(name).svg"),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }), let image = NSImage(contentsOf: url) else { return nil }
        let height: CGFloat = 14
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: (height * aspect).rounded(), height: height)
        image.isTemplate = true
        image.accessibilityDescription = "OpenCode Go"
        return image
    }
}
