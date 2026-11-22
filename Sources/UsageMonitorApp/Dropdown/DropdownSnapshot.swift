import AppKit
import SwiftUI
import UsageCore

/// Offscreen PNG renders of the dropdown for review (no window, no display needed).
@MainActor
enum DropdownSnapshot {
    /// The dropdown for `model`, on the mockup's surface color.
    static func png(_ model: DashboardModel, clock: DropdownClock, scheme: ColorScheme) -> Data? {
        let palette = DropdownPalette.forScheme(scheme)
        return png(DropdownView(model: model, clock: clock).background(palette.surface), scheme: scheme)
    }

    /// One provider row's hover card.
    static func hoverPNG(_ row: ProviderRow, clock: DropdownClock, scheme: ColorScheme) -> Data? {
        let palette = DropdownPalette.forScheme(scheme)
        return png(RowHoverView(hover: RowHover(row: row, clock: clock)).background(palette.surface),
                   scheme: scheme)
    }

    /// Lays out `view` at its fitting size in an `NSHostingView` and draws it with
    /// `bitmapImageRepForCachingDisplay`, at 2x.
    static func png(_ view: some View, scheme: ColorScheme, scale: CGFloat = 2) -> Data? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        // Without a window the rep is 1x; draw into a rep of the same point size at
        // `scale` instead.
        let target: NSBitmapImageRep
        if CGFloat(rep.pixelsWide) < size.width * scale, let big = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            big.size = size
            target = big
        } else {
            target = rep
        }
        host.cacheDisplay(in: host.bounds, to: target)
        return target.representation(using: .png, properties: [:])
    }
}
