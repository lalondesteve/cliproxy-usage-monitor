import AppKit
import UsageCore

/// What the status item shows, apart from the button: the entries, the last error,
/// and from them the image and tooltip. Kept out of the controller so it can be tested
/// without a real status item.
@MainActor
struct StatusDisplay {
    private(set) var entries: [StatusEntry] = []
    private(set) var errorTooltip: String?

    mutating func show(_ model: DashboardModel) {
        entries = StatusEntry.entries(for: model)
        errorTooltip = nil
    }

    /// No model to show: the item falls back to the compact glyph, the error goes in
    /// the tooltip.
    mutating func showError(_ message: String) {
        entries = []
        errorTooltip = "Usage Monitor: \(message)"
    }

    /// With no provider to show, even Normal draws the compact glyph so the item stays
    /// clickable.
    func image(showsProviders: Bool, logo: (Provider) -> NSImage?, glyph: NSImage?) -> NSImage {
        if showsProviders, !entries.isEmpty {
            return StatusImage.normal(entries, logo: logo)
        }
        return StatusImage.compact(glyph: glyph)
    }

    func tooltip(for image: NSImage) -> String? {
        errorTooltip ?? image.accessibilityDescription
    }
}
