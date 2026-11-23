import AppKit
import Foundation
import SwiftUI
import Testing
import UsageCore
@testable import UsageMonitorApp

/// Renders the E1 to E4 dropdowns (and an everything-at-once model plus two hover
/// cards) to build/review/T9b/ for the user to compare with
/// docs/mockups/gauges-overlap.html. Light is `<name>.png`, dark `<name>-dark.png`.
@Suite("T9b snapshots")
@MainActor
struct T9bSnapshotTests {
    typealias E = T9bExamples

    static let outputDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/review/T9b")

    private func write(_ data: Data?, _ name: String) throws -> NSBitmapImageRep {
        let data = try #require(data, "no PNG for \(name)")
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        try data.write(to: Self.outputDir.appendingPathComponent("\(name).png"))
        return try #require(NSBitmapImageRep(data: data))
    }

    @Test(arguments: [("E1", E.e1), ("E2", E.e2), ("E3", E.e3), ("E4", E.e4), ("all", E.all), ("long-aux", E.longAux)])
    func rendersDropdown(name: String, model: DashboardModel) throws {
        for (scheme, suffix) in [(ColorScheme.light, ""), (.dark, "-dark")] {
            let rep = try write(DropdownSnapshot.png(model, clock: E.clock, scheme: scheme), name + suffix)
            // 2x of the 360 pt popover width, and not blank: the surface color plus ink.
            #expect(rep.pixelsWide == Int(DropdownLayout.width * 2))
            #expect(rep.pixelsHigh > 100)
            #expect(distinctColors(rep) > 4)
        }
    }

    @Test func rendersHoverCards() throws {
        for (name, row) in [("E2-hover", E.e2.rows[0]), ("E8-hover", E.e8Codex), ("long-aux-hover", E.longAux.rows[0])] {
            let rep = try write(DropdownSnapshot.hoverPNG(row, clock: E.clock, scheme: .light), name)
            #expect(rep.pixelsWide > 200)
            #expect(distinctColors(rep) > 4)
        }
    }

    @Test func overlapLinePixelsMatchTheGeometry() throws {
        // The rendered line itself: draw E2's bars at 200 pt and sample the middle row.
        let palette = DropdownPalette.light
        let view = OverlapLineView(bars: E.e2Five.bars, palette: palette).frame(width: 200)
        let png = try #require(DropdownSnapshot.png(view, scheme: .light, scale: 1))
        let rep = try #require(NSBitmapImageRep(data: png))
        let y = rep.pixelsHigh / 2
        // `bitmapImageRepForCachingDisplay` follows the main screen's scale, so the
        // rep can be 2x even when asked for 1x; sample in points.
        let k = rep.pixelsWide / 200
        func color(_ x: Int) -> NSColor { rep.colorAt(x: x * k, y: y)!.usingColorSpace(.sRGB)! }
        func close(_ a: NSColor, _ b: Color) -> Bool {
            let b = NSColor(b).usingColorSpace(.sRGB)!
            return abs(a.redComponent - b.redComponent) < 0.03
                && abs(a.greenComponent - b.greenComponent) < 0.03
                && abs(a.blueComponent - b.blueComponent) < 0.03
        }
        #expect(close(color(1), palette.series[1]))    // B blocked: tick at 0
        #expect(close(color(35), palette.series[2]))   // C (35) on top up to 70
        #expect(close(color(85), palette.series[0]))   // A up to 160
        #expect(close(color(130), palette.series[0]))
        #expect(close(color(180), palette.track))      // empty track after
    }

    private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 60)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5
                    | UInt32(c.blueComponent * 31)
                seen.insert(key)
                if seen.count > 50 { return seen.count }
            }
        }
        return seen.count
    }
}
