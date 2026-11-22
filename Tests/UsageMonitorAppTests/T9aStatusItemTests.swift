import AppKit
import Foundation
import Testing
import UsageCore
@testable import UsageMonitorApp

private let t0 = Date(timeIntervalSince1970: 1_764_000_000)

private func gauge(_ range: PercentRange?) -> WindowGauge {
    WindowGauge(window: .fiveHour, known: 3, total: 3, quota: range, usable: range, bars: [],
                nextRefill: nil, allFull: false, pace: nil, accounts: [])
}

private func row(_ provider: Provider, _ range: PercentRange?) -> ProviderRow {
    ProviderRow(provider: provider, fiveHour: gauge(range), weekly: nil, monthly: nil,
                unclassified: [], forecast: nil)
}

private func model(rows: [ProviderRow], sources: [SourceKind: SourceStatus]) -> DashboardModel {
    DashboardModel(generatedAt: t0, rows: rows, sources: sources)
}

@Suite("T9a layout")
struct T9aLayoutTests {
    @Test func oneProvider() {
        let layout = StatusLayout.normal(textWidths: [26])
        #expect(layout.slots == [.init(glyphX: 0, textX: 17, textWidth: 26)])
        #expect(layout.width == CGFloat(14 + 3 + 26))
    }

    @Test func threeProvidersAreTenApart() {
        let layout = StatusLayout.normal(textWidths: [26, 40, 18])
        #expect(layout.slots == [
            .init(glyphX: 0, textX: 17, textWidth: 26),
            .init(glyphX: 53, textX: 70, textWidth: 40),     // 43 + 10
            .init(glyphX: 120, textX: 137, textWidth: 18),   // 110 + 10
        ])
        #expect(layout.width == 155)
    }

    @Test func fractionalTextWidthsRoundUpSoTextIsNeverClipped() {
        let layout = StatusLayout.normal(textWidths: [25.2, 30.01])
        #expect(layout.slots.map(\.textWidth) == [26, 31])
        #expect(layout.slots[1].glyphX == CGFloat(14 + 3 + 26 + 10))
        #expect(layout.width == CGFloat(101))   // 14 + 3 + 26 + 10 + 14 + 3 + 31
    }

    @Test func noProviders() {
        #expect(StatusLayout.normal(textWidths: []) == .init(slots: [], width: 0))
    }

    @Test func compactGlyphIs16() {
        #expect(StatusLayout.compactGlyphSize == 16)
    }

    @Test func tallLogoIsCenteredInItsBox() {
        // OpenCode's logo is 32 x 40.
        let rect = StatusLayout.aspectFit(aspect: 32.0 / 40, box: 14, origin: CGPoint(x: 10, y: 2))
        #expect(abs(rect.width - 11.2) < 1e-9)
        #expect(rect.height == 14)
        #expect(abs(rect.minX - 11.4) < 1e-9)
        #expect(rect.minY == 2)
    }
}

@Suite("T9a entries")
struct T9aEntryTests {
    @Test func notConfiguredSourceHidesItsProviders() {
        let m = model(rows: [row(.claude, PercentRange(exact: 80)), row(.codex, PercentRange(exact: 60)),
                             row(.go, PercentRange(exact: 48))],
                      sources: [.cliproxy: .notConfigured, .ocgo: .ok(at: t0)])
        #expect(StatusEntry.entries(for: m) == [StatusEntry(provider: .go, text: "48%")])
    }

    @Test func missingSourceStatusHidesItsProviders() {
        let m = model(rows: [row(.claude, PercentRange(exact: 80)), row(.go, PercentRange(exact: 48))],
                      sources: [.cliproxy: .ok(at: t0)])
        #expect(StatusEntry.entries(for: m).map(\.provider) == [.claude])
    }

    @Test func providerWithoutRowIsHidden() {
        let m = model(rows: [row(.codex, PercentRange(exact: 60))],
                      sources: [.cliproxy: .ok(at: t0), .ocgo: .ok(at: t0)])
        #expect(StatusEntry.entries(for: m) == [StatusEntry(provider: .codex, text: "60%")])
    }

    @Test func rangeUnknownAndFailingSource() {
        // E1: 41-74%. A failing source still shows its row; unknown shows "--".
        let noFiveHour = ProviderRow(provider: .go, fiveHour: nil, weekly: nil, monthly: nil,
                                     unclassified: [], forecast: nil)
        let m = model(rows: [noFiveHour, row(.codex, nil),
                             row(.claude, PercentRange(lower: 123.0 / 3, upper: 223.0 / 3))],
                      sources: [.cliproxy: .failing(.timeout, since: t0), .ocgo: .ok(at: t0)])
        #expect(StatusEntry.entries(for: m) == [
            StatusEntry(provider: .claude, text: "41-74%"),
            StatusEntry(provider: .codex, text: "--"),
            StatusEntry(provider: .go, text: "--"),
        ])
    }

    @Test func showsUsableNotQuota() {
        // E2: A 80 usable, B 50 blocked by weekly, C 35 usable: quota 55%, usable 38% (115/3).
        let e2 = WindowGauge(window: .fiveHour, known: 3, total: 3, quota: PercentRange(exact: 55),
                             usable: PercentRange(exact: 115.0 / 3), bars: [], nextRefill: nil,
                             allFull: false, pace: nil, accounts: [])
        let m = model(rows: [ProviderRow(provider: .claude, fiveHour: e2, weekly: nil, monthly: nil,
                                         unclassified: [], forecast: nil)],
                      sources: [.cliproxy: .ok(at: t0)])
        #expect(StatusEntry.entries(for: m) == [StatusEntry(provider: .claude, text: "38%")])
    }
}

@Suite("T9a tooltip")
@MainActor
struct T9aDisplayTests {
    private let go48 = model(rows: [row(.go, PercentRange(exact: 48))],
                             sources: [.ocgo: .ok(at: t0), .cliproxy: .notConfigured])
    private let empty = model(rows: [], sources: [.ocgo: .notConfigured, .cliproxy: .notConfigured])

    private func tooltip(_ d: StatusDisplay) -> String? {
        d.tooltip(for: d.image(showsProviders: true, logo: { _ in nil }, glyph: nil))
    }

    @Test func tooltipFollowsTheLatestModel() {
        var d = StatusDisplay()
        d.show(go48)
        #expect(tooltip(d) == "OpenCode Go 48%")
        d.show(empty)
        #expect(tooltip(d) == "Usage Monitor")
    }

    @Test func errorTooltipClearsOnTheNextModel() {
        var d = StatusDisplay()
        d.show(go48)
        d.showError("no token")
        #expect(d.entries.isEmpty)
        #expect(tooltip(d) == "Usage Monitor: no token")
        d.show(empty)
        #expect(tooltip(d) == "Usage Monitor")
        d.showError("no token")
        d.show(go48)
        #expect(tooltip(d) == "OpenCode Go 48%")
    }
}

@Suite("T9a compact expander")
@MainActor
struct T9aExpanderTests {
    final class Counter { var value = 0 }

    private func make(_ style: MenubarStyle) -> (CompactExpander, T9aManualScheduler, Counter) {
        let scheduler = T9aManualScheduler()
        let expander = CompactExpander(style: style, scheduler: scheduler)
        let opened = Counter()
        expander.onOpenDropdown = { opened.value += 1 }
        return (expander, scheduler, opened)
    }

    @Test func clickExpandsForThreeSeconds() {
        let (e, clock, opened) = make(.compact)
        let changes = Counter()
        e.onStateChange = { changes.value += 1 }
        #expect(e.state == .collapsed)
        #expect(!e.showsProviders)

        #expect(e.click() == .expanded)
        #expect(e.state == .expanded)
        #expect(e.showsProviders)

        clock.advance(by: 2.9)
        #expect(e.state == .expanded)
        clock.advance(by: 0.1)
        #expect(e.state == .collapsed)
        #expect(!e.showsProviders)
        #expect(changes.value == 2)
        #expect(opened.value == 0)
        #expect(clock.pendingCount == 0)
    }

    @Test func clickWhileExpandedOpensTheDropdown() {
        let (e, clock, opened) = make(.compact)
        e.click()
        clock.advance(by: 1)
        #expect(e.click() == .openDropdown)
        #expect(opened.value == 1)
        // The second click keeps the first click's 3 s deadline, dropdown open or not.
        clock.advance(by: 1.9)
        #expect(e.state == .expanded)
        clock.advance(by: 0.1)
        #expect(e.state == .collapsed)
        #expect(!e.showsProviders)
        // The next click expands again rather than opening the dropdown.
        #expect(e.click() == .expanded)
        #expect(opened.value == 1)
    }

    @Test func compactWithNothingToShowOpensTheDropdownAtOnce() {
        let (e, clock, opened) = make(.compact)
        e.hasEntries = false
        #expect(e.click() == .openDropdown)
        #expect(opened.value == 1)
        #expect(e.state == .collapsed)
        #expect(clock.pendingCount == 0)
        e.hasEntries = true
        #expect(e.click() == .expanded)
        #expect(opened.value == 1)
    }

    @Test func clickAfterCollapseExpandsAgain() {
        let (e, clock, opened) = make(.compact)
        e.click()
        clock.advance(by: 3)
        #expect(e.click() == .expanded)
        #expect(opened.value == 0)
        clock.advance(by: 3)
        #expect(e.state == .collapsed)
    }

    @Test func normalClickOpensTheDropdown() {
        let (e, clock, opened) = make(.normal)
        #expect(e.showsProviders)
        #expect(e.click() == .openDropdown)
        #expect(opened.value == 1)
        #expect(e.state == .collapsed)
        #expect(clock.pendingCount == 0)
    }

    @Test func switchingStyleCollapsesAndCancelsTheTimer() {
        let (e, clock, _) = make(.compact)
        e.click()
        e.style = .normal
        #expect(e.state == .collapsed)
        #expect(clock.pendingCount == 0)
        e.style = .compact
        #expect(!e.showsProviders)
    }
}

@Suite("T9a image")
@MainActor
struct T9aImageTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func logo(_ p: Provider) -> NSImage? { StatusAssets.logo(p, repoRoot: Self.repoRoot) }

    @Test func assetsLoad() {
        for p in Provider.allCases { #expect(logo(p) != nil, "logo for \(p)") }
        #expect(StatusAssets.compactGlyph(repoRoot: Self.repoRoot) != nil)
    }

    @Test func imageWidthCoversTextMeasuredInTheMenubarFont() {
        let font = StatusImage.font
        #expect(font.pointSize == NSFont.menuBarFont(ofSize: 0).pointSize)
        let entries = [StatusEntry(provider: .claude, text: "41-74%"), StatusEntry(provider: .go, text: "48%")]
        let image = StatusImage.normal(entries, font: font, logo: logo)
        let w1 = StatusImage.textWidth("41-74%", font: font)
        let w2 = StatusImage.textWidth("48%", font: font)
        #expect(w2 > 0)
        #expect(image.size.width == 14 + 3 + w1.rounded(.up) + 10 + 14 + 3 + w2.rounded(.up))
        #expect(image.size.height >= 16)
        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == "Claude 41-74%, OpenCode Go 48%")
    }

    @Test func compactImageIsTheGlyph() {
        let image = StatusImage.compact(glyph: StatusAssets.compactGlyph(repoRoot: Self.repoRoot))
        #expect(image.size.width == 16)
        #expect(image.isTemplate)
    }

    @Test func imageOnlyButtonIsAtLeastAsWideAsTheImage() {
        let image = StatusImage.normal([StatusEntry(provider: .go, text: "48%")], logo: logo)
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        #expect(button.fittingSize.width >= image.size.width)
    }

    /// Writes review PNGs when T9A_REVIEW_DIR is set (e.g. build/review/T9a, relative
    /// to the repo root).
    @Test func reviewPNGs() throws {
        guard let dir = ProcessInfo.processInfo.environment["T9A_REVIEW_DIR"] else { return }
        let out = URL(fileURLWithPath: dir, relativeTo: Self.repoRoot)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases: [(String, NSImage)] = [
            ("normal-go-48", StatusImage.normal([StatusEntry(provider: .go, text: "48%")], logo: logo)),
            ("normal-three", StatusImage.normal([
                StatusEntry(provider: .claude, text: "41-74%"),
                StatusEntry(provider: .codex, text: "--"),
                StatusEntry(provider: .go, text: "48%"),
            ], logo: logo)),
            ("compact", StatusImage.compact(glyph: StatusAssets.compactGlyph(repoRoot: Self.repoRoot))),
        ]
        for (name, image) in cases {
            let png = try #require(StatusImage.reviewPNG(image))
            try png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }
}
