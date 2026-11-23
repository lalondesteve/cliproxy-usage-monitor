import Foundation
import Testing
@testable import UsageCore

/// T10 fixture replay: the coordinator, with a transport serving a capture folder and
/// the clock fixed at EXPECTED.md's "as of" time, publishes a `DashboardModel` whose
/// pooled values equal EXPECTED.md.
///
/// `Fixtures/live/` comes from P0.3 (scripts/capture-fixtures.sh plus a hand-written
/// EXPECTED.md). Until it exists the live test is skipped, not failed; don't delete it.
/// The same replay runs on `Fixtures/synthetic/T10/`, a small capture with a hand-made
/// EXPECTED.md, so the replay and the sheet parser are exercised now.
///
/// EXPECTED.md format (nothing else defines one; any line not described here is a
/// comment, so the file can carry its working):
///
///     as of: 2026-11-22T12:00:00Z
///     alias: claude-x@example.com.json = 1a2b3c4d      (optional, repeatable)
///
///     | provider | window | known | quota   | usable  |
///     |----------|--------|-------|---------|---------|
///     | claude   | 5h     | 2/3   | 40-73.3 | 40-73.3 |
///     | go       | weekly |       | 65      |         |
///
/// - `as of`: the capture time (RFC 3339); the replay's clock is fixed there.
/// - `alias`: a Settings identity alias (`fileKey = identity`), passed as PoolSettings.
/// - Table: the header names the columns, in any order. `provider` (claude, codex, go),
///   `window` (5h or fiveHour, weekly, monthly) and `quota` are required; `known`
///   ("known/total") and `usable` are optional. Every row has a cell for every column,
///   and a non-empty `quota` (`-` when nil is expected). A percent is a number or a
///   range `lower-upper`; `-` means nil (no known or enabled account); an empty
///   `known` or `usable` cell isn't checked. Percents match within 0.5 points. Every
///   listed provider must have a row.
@Suite("T10 fixture replay")
struct T10FixtureReplayTests {
    static let liveFolder = Fixtures.url("live")
    static let syntheticFolder = Fixtures.url("synthetic/T10")

    static var liveSheetExists: Bool {
        FileManager.default.fileExists(atPath: liveFolder.appendingPathComponent("EXPECTED.md").path)
    }

    @Test(.enabled(if: liveSheetExists,
                   "No Fixtures/live/EXPECTED.md yet: P0.3 hasn't captured and worked out the live fixtures"))
    func liveCaptureMatchesExpected() async throws {
        try await Self.replayAndCompare(Self.liveFolder)
    }

    @Test func syntheticCaptureMatchesExpected() async throws {
        let (model, transport) = try await Self.replayAndCompare(Self.syntheticFolder)
        // Every endpoint was read once: credential list, routing, config, fork history, ocgo.
        #expect(Set(transport.paths) == Set(T10FolderTransport.files.keys))
        #expect(transport.paths.count == T10FolderTransport.files.count)
        #expect(model.rows.map(\.provider) == [.claude, .codex, .go])
        #expect(model.sources[.cliproxy] == .ok(at: date("2026-11-22T12:00:00Z")))
        #expect(model.sources[.ocgo] == .ok(at: date("2026-11-22T12:00:00Z")))
        // T11d: every row has a forecast; one capture holds at most two reading times
        // per account, so there is no burn rate and no lockout forecast yet.
        #expect(model.rows.allSatisfy {
            $0.forecast?.poolBurnPerHour == nil && $0.forecast?.lockout == .insufficientData
        })
    }

    /// A sheet that disagrees with the capture fails: the comparison isn't vacuous.
    @Test func wrongExpectationIsReported() async throws {
        let sheet = try T10ExpectedSheet.parse(try Fixtures.data("synthetic/T10/EXPECTED.md"))
        let model = try await Self.replay(Self.syntheticFolder, sheet: sheet)
        var wrong = sheet
        wrong.rows[0].quota = .value(PercentRange(lower: 41, upper: 73.3))
        #expect(!Self.mismatches(model, wrong).isEmpty)
        #expect(Self.mismatches(model, sheet).isEmpty)
    }

    // MARK: Sheet parser

    @Test func parsesTheSyntheticSheet() throws {
        let sheet = try T10ExpectedSheet.parse(try Fixtures.data("synthetic/T10/EXPECTED.md"))
        #expect(sheet.asOf == date("2026-11-22T12:00:00Z"))
        #expect(sheet.aliases.isEmpty)
        #expect(sheet.rows.count == 7)
        let first = try #require(sheet.rows.first)
        #expect(first.provider == .claude && first.window == .fiveHour)
        #expect(first.known == T10ExpectedSheet.Known(known: 2, total: 3))
        #expect(first.quota == .value(PercentRange(lower: 40, upper: 73.3)))
        #expect(first.usable == .value(PercentRange(lower: 40, upper: 73.3)))
        let goWeekly = try #require(sheet.rows.first { $0.provider == .go && $0.window == .weekly })
        #expect(goWeekly.quota == .value(PercentRange(exact: 65)))
        #expect(goWeekly.usable == .unchecked)
    }

    @Test func parsesAliasesNilAndColumnOrder() throws {
        let sheet = try T10ExpectedSheet.parse(Data("""
            Notes before.
            as of: 2026-11-22T12:00:00.500Z
            alias: claude-x@example.com.json = 1a2b3c4d

            | window | quota | provider | usable |
            |---|---|---|---|
            | fiveHour | - | codex | 12.5 |
            """.utf8))
        #expect(sheet.asOf == date("2026-11-22T12:00:00.500Z"))
        #expect(sheet.aliases == ["claude-x@example.com.json": "1a2b3c4d"])
        #expect(sheet.rows == [T10ExpectedSheet.Row(provider: .codex, window: .fiveHour, known: nil,
                                                    quota: .none, usable: .value(PercentRange(exact: 12.5)))])
    }

    @Test func rejectsMalformedSheets() {
        let table = "| provider | window | quota |\n|---|---|---|\n| go | 5h | 55 |"
        #expect(throws: T10ExpectedSheet.ParseError.self) { try T10ExpectedSheet.parse(Data(table.utf8)) }
        for bad in ["| provider | window | quota |\n|---|---|---|\n| gemini | 5h | 55 |",
                    "| provider | window | quota |\n|---|---|---|\n| go | daily | 55 |",
                    "| provider | window | quota |\n|---|---|---|\n| go | 5h | lots |",
                    "| provider | quota |\n|---|---|\n| go | 55 |",
                    "| provider | window | quota |\n|---|---|---|",
                    // Truncated rows, and an empty quota cell, are refused.
                    "| provider | window | quota |\n|---|---|---|\n| go | weekly |",
                    "| provider | window | known | quota |\n|---|---|---|---|\n| go | weekly | 2/2 |",
                    "| provider | window | quota | usable |\n|---|---|---|---|\n| go | weekly |  |  |"] {
            #expect(throws: T10ExpectedSheet.ParseError.self) {
                try T10ExpectedSheet.parse(Data("as of: 2026-11-22T12:00:00Z\n\(bad)".utf8))
            }
        }
    }

    // MARK: Replay

    @discardableResult
    static func replayAndCompare(_ folder: URL) async throws -> (DashboardModel, T10FolderTransport) {
        let sheet = try T10ExpectedSheet.parse(try Data(contentsOf: folder.appendingPathComponent("EXPECTED.md")))
        let transport = T10FolderTransport(folder: folder)
        let model = try await replay(folder, sheet: sheet, transport: transport)
        for problem in mismatches(model, sheet) { Issue.record(Comment(rawValue: problem)) }
        return (model, transport)
    }

    static func replay(_ folder: URL, sheet: T10ExpectedSheet,
                       transport: T10FolderTransport? = nil) async throws -> DashboardModel {
        let transport = transport ?? T10FolderTransport(folder: folder)
        var configured: Set<SourceKind> = []
        if transport.file("/v8/management/credentials") != nil { configured.insert(.cliproxy) }
        if transport.file("/_ocgo/status") != nil { configured.insert(.ocgo) }
        let pipeline = try T10Pipeline(transport: transport, clock: FixedNowProvider(sheet.asOf),
                                       settings: PoolSettings(identityAliases: sheet.aliases),
                                       configured: configured)
        await pipeline.coordinator.tick()
        return try #require(await pipeline.coordinator.model)
    }

    static func mismatches(_ model: DashboardModel, _ sheet: T10ExpectedSheet) -> [String] {
        var problems: [String] = []
        for row in sheet.rows {
            let name = "\(row.provider.rawValue) \(row.window.rawValue)"
            guard let providerRow = model.row(row.provider) else {
                problems.append("\(name): no \(row.provider.rawValue) row in the dashboard")
                continue
            }
            let gauge: WindowGauge? = switch row.window {
            case .fiveHour: providerRow.fiveHour
            case .weekly: providerRow.weekly
            case .monthly: providerRow.monthly
            }
            if let known = row.known, known != gauge.map({ .init(known: $0.known, total: $0.total) }) {
                problems.append("\(name): known \(gauge.map { "\($0.known)/\($0.total)" } ?? "no gauge"), "
                    + "expected \(known.known)/\(known.total)")
            }
            for (column, expected, actual) in [("quota", row.quota, gauge?.quota),
                                               ("usable", row.usable, gauge?.usable)] {
                if !expected.matches(actual) {
                    problems.append("\(name): \(column) \(actual.map(describe) ?? "nil"), expected \(expected)")
                }
            }
        }
        return problems
    }

    static func describe(_ r: PercentRange) -> String {
        r.lower == r.upper ? "\(r.lower)" : "\(r.lower)-\(r.upper)"
    }
}

/// A parsed EXPECTED.md (format in `T10FixtureReplayTests`).
struct T10ExpectedSheet: Equatable {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    struct Known: Equatable {
        let known: Int
        let total: Int
    }

    enum Expectation: Equatable, CustomStringConvertible {
        case unchecked
        case none
        case value(PercentRange)

        static let tolerance = 0.5

        func matches(_ actual: PercentRange?) -> Bool {
            switch self {
            case .unchecked: true
            case .none: actual == nil
            case .value(let e):
                actual.map { abs($0.lower - e.lower) <= Self.tolerance && abs($0.upper - e.upper) <= Self.tolerance }
                    ?? false
            }
        }

        var description: String {
            switch self {
            case .unchecked: "(unchecked)"
            case .none: "nil"
            case .value(let r): T10FixtureReplayTests.describe(r)
            }
        }
    }

    struct Row: Equatable {
        let provider: Provider
        let window: WindowKind
        let known: Known?
        var quota: Expectation
        let usable: Expectation
    }

    let asOf: Date
    let aliases: [String: String]
    var rows: [Row]

    static func parse(_ data: Data) throws -> T10ExpectedSheet {
        var asOf: Date?
        var aliases: [String: String] = [:]
        var header: [String]?
        var rows: [Row] = []
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.wholeMatch(of: #/(?i)as of:\s*(\S+)/#) {
                guard let d = instant(String(m.1)) else { throw ParseError(description: "bad as-of time \(m.1)") }
                asOf = d
            } else if let m = line.wholeMatch(of: #/(?i)alias:\s*(\S+)\s*=\s*(\S+)/#) {
                aliases[String(m.1)] = String(m.2)
            } else if line.hasPrefix("|") {
                var cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                cells = Array(cells.dropFirst())
                if cells.last == "" { cells.removeLast() }
                if cells.allSatisfy({ $0.wholeMatch(of: #/:?-+:?/#) != nil }) { continue }
                guard let columns = header else {
                    header = cells.map { $0.lowercased() }
                    for required in ["provider", "window", "quota"] where !header!.contains(required) {
                        throw ParseError(description: "table has no \(required) column")
                    }
                    continue
                }
                rows.append(try row(cells, columns: columns))
            }
        }
        guard let asOf else { throw ParseError(description: "no \"as of:\" line") }
        guard !rows.isEmpty else { throw ParseError(description: "no expected rows") }
        return T10ExpectedSheet(asOf: asOf, aliases: aliases, rows: rows)
    }

    private static func row(_ cells: [String], columns: [String]) throws -> Row {
        guard cells.count >= columns.count else {
            throw ParseError(description: "row has \(cells.count) cells for \(columns.count) columns: \(cells)")
        }
        func cell(_ name: String) -> String {
            columns.firstIndex(of: name).flatMap { $0 < cells.count ? cells[$0] : nil } ?? ""
        }
        guard let provider = Provider(rawValue: cell("provider").lowercased()) else {
            throw ParseError(description: "unknown provider \(cell("provider"))")
        }
        let window: WindowKind
        switch cell("window").lowercased() {
        case "5h", "fivehour": window = .fiveHour
        case "weekly": window = .weekly
        case "monthly": window = .monthly
        default: throw ParseError(description: "unknown window \(cell("window"))")
        }
        var known: Known?
        if !cell("known").isEmpty {
            guard let m = cell("known").wholeMatch(of: #/(\d+)\s*/\s*(\d+)/#), let k = Int(m.1), let t = Int(m.2)
            else { throw ParseError(description: "bad known \(cell("known"))") }
            known = Known(known: k, total: t)
        }
        let quota = try expectation(cell("quota"))
        guard quota != .unchecked else { throw ParseError(description: "row \(cells) has no quota") }
        return Row(provider: provider, window: window, known: known,
                   quota: quota, usable: try expectation(cell("usable")))
    }

    private static func expectation(_ text: String) throws -> Expectation {
        let t = text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: " ", with: "")
        if t.isEmpty { return .unchecked }
        if t == "-" || t.lowercased() == "nil" || t.lowercased() == "none" { return .none }
        if let m = t.wholeMatch(of: #/(\d+(?:\.\d+)?)(?:-(\d+(?:\.\d+)?))?/#), let lower = Double(m.1) {
            let upper = m.2.flatMap { Double($0) } ?? lower
            return .value(PercentRange(lower: lower, upper: upper))
        }
        throw ParseError(description: "bad percent \(text)")
    }

    private static func instant(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
