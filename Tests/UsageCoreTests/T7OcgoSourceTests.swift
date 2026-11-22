import Foundation
import Testing
@testable import UsageCore

/// Expected values come from plan.md "Reading the status" and worked examples E9, E10
/// and E16 (docs/implementation-plan.md), not from running the parser.
@Suite("T7 ocgo source")
struct T7OcgoSourceTests {
    let config = SourceConfig(url: URL(string: "http://ocgo.test:8320")!, secret: "tok")

    /// Runs a fixture through the whole source (transport, status mapping, parser).
    func fetch(_ name: String, at now: String = "2026-11-22T12:00:00Z") async throws -> SourceSnapshot {
        let transport = RecordingTransport(body: try Fixtures.data("synthetic/T7/\(name)"))
        let source = OcgoSource(config: config, transport: transport, now: FixedNowProvider(date(now)))
        return try await source.fetch(since: nil).get()
    }

    func parse(_ json: String, at now: String = "2026-11-22T12:00:00Z") throws -> SourceSnapshot {
        try OcgoStatusParser.snapshot(from: Data(json.utf8), takenAt: date(now)).get()
    }

    func reading(_ s: SourceSnapshot, _ fileKey: String, _ window: WindowKind) -> SourceReading? {
        s.readings.first { $0.fileKey == fileKey && $0.window == window }
    }

    func account(_ s: SourceSnapshot, _ fileKey: String) -> AccountSnapshot? {
        s.accounts.first { $0.fileKey == fileKey }
    }

    // MARK: All three windows

    @Test func mapsAllThreeWindows() async throws {
        let s = try await fetch("three-windows.json")
        let a = date("2026-11-22T11:58:00Z")
        let b = date("2026-11-22T11:58:30Z")
        let expected: Set<SourceReading> = [
            SourceReading(provider: .go, fileKey: "team-a", window: .fiveHour, usedPercent: 62,
                          resetsAt: date("2026-11-22T14:10:00Z"), observedAt: a, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-a", window: .weekly, usedPercent: 27.5,
                          resetsAt: date("2026-11-26T09:00:00Z"), observedAt: a, source: .ocgo),
            // 104 clamps to 100
            SourceReading(provider: .go, fileKey: "team-a", window: .monthly, usedPercent: 100,
                          resetsAt: date("2026-12-01T00:00:00Z"), observedAt: a, source: .ocgo),
            // -3 clamps to 0; Go zero time is an unset reset (E15 shape)
            SourceReading(provider: .go, fileKey: "team-b", window: .fiveHour, usedPercent: 0,
                          resetsAt: nil, observedAt: b, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-b", window: .weekly, usedPercent: 20,
                          resetsAt: date("2026-11-27T08:00:00Z"), observedAt: b, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-b", window: .monthly, usedPercent: 8,
                          resetsAt: date("2026-12-01T00:00:00Z"), observedAt: b, source: .ocgo),
        ]
        // The unknown "daily" window gives nothing, in readings or unclassified.
        #expect(s.readings.count == 6)
        #expect(Set(s.readings) == expected)
        #expect(s.unclassified.isEmpty)
        #expect(s.routing == RoutingConfig(strategy: .mostHeadroom, sessionAffinity: false, forcedAccount: nil))
    }

    // MARK: E9

    @Test func e9NeverPolledIsUnknown() async throws {
        let s = try await fetch("e9-never-polled.json")
        #expect(s.accounts.map(\.fileKey) == ["team-a", "team-fresh", "team-zero"])
        // No readings at all: not 100% left (percent 0) and not 0% either.
        #expect(s.readings.filter { $0.fileKey != "team-a" }.isEmpty)
        #expect(account(s, "team-fresh")?.polledAt == nil)
        #expect(account(s, "team-zero")?.polledAt == nil, "Go zero time means never polled")
        #expect(account(s, "team-fresh")?.unavailable == [])
        // The polled account is read normally.
        #expect(s.readings.filter { $0.fileKey == "team-a" }.map(\.window).sorted { $0.rawValue < $1.rawValue }
                == [.fiveHour, .monthly, .weekly])
        #expect(reading(s, "team-a", .fiveHour)?.usedPercent == 52)
    }

    // MARK: E10 and forced_account

    @Test func e10ForcedAccount() async throws {
        let s = try await fetch("e10-forced.json")
        #expect(s.routing?.forcedAccount == AccountID(provider: .go, identity: "team-b"))
        #expect(s.routing?.strategy == .mostHeadroom)
        #expect(account(s, "team-a")?.unavailable == [.notForcedAccount])
        // team-b's cooldown is advisory while forced: usable.
        #expect(account(s, "team-b")?.unavailable == [])
        // Both accounts still show their quota.
        #expect(reading(s, "team-a", .fiveHour)?.usedPercent == 30)
        #expect(reading(s, "team-b", .fiveHour)?.usedPercent == 45)
        #expect(s.readings.count == 6)
    }

    @Test func forcedAccountHasNoAccountLevelReason() throws {
        let s = try parse("""
        { "forced_account": "team-b", "accounts": [
          { "name": "team-a", "available": false, "exhausted": true,
            "exhausted_until": "2026-11-23T00:00:00Z", "polled_at": "2026-11-22T11:59:00Z" },
          { "name": "team-b", "available": false, "exhausted": true,
            "exhausted_until": "2026-11-22T15:00:00Z", "cooldown_until": "2026-11-22T12:30:00Z",
            "polled_at": "2026-11-22T11:59:00Z" },
          { "name": "team-c", "available": true, "cooldown_until": "2026-11-22T12:30:00Z",
            "polled_at": "2026-11-22T11:59:00Z" }
        ] }
        """)
        #expect(account(s, "team-a")?.unavailable
                == [.notForcedAccount, .exhausted(until: date("2026-11-23T00:00:00Z"))])
        // Forced: ocgo skips its availability check, so only its windows decide.
        #expect(account(s, "team-b")?.unavailable == [])
        #expect(account(s, "team-c")?.unavailable == [.notForcedAccount])
    }

    @Test func forcedAccountIgnoresExhaustedEvenWhenAvailable() throws {
        let team = """
          { "name": "team-b", "available": true, "exhausted": true,
            "exhausted_until": "2026-11-22T15:00:00Z", "polled_at": "2026-11-22T11:59:00Z" }
        """
        let forced = try parse(#"{ "forced_account": "team-b", "accounts": [ \#(team) ] }"#)
        #expect(account(forced, "team-b")?.unavailable == [])
        // The same account unforced follows `available: true`.
        let unforced = try parse(#"{ "accounts": [ \#(team) ] }"#)
        #expect(account(unforced, "team-b")?.unavailable == [])
    }

    // MARK: Lenient windows

    @Test func badWindowDoesNotDropTheSnapshot() throws {
        let s = try parse("""
        { "accounts": [ { "name": "team-a", "available": true, "polled_at": "2026-11-22T11:59:00Z",
            "windows": {
              "rolling": { "status": "ok", "percent": 40, "resets_at": "2026-11-22T14:00:00Z" },
              "weekly": { "status": "error", "percent": "n/a" },
              "monthly": "broken"
            } },
          { "name": "team-b", "available": true, "polled_at": "2026-11-22T11:59:00Z",
            "windows": { "rolling": { "status": "ok", "percent": "42" },
                         "weekly": null } } ] }
        """)
        #expect(s.accounts.map(\.fileKey) == ["team-a", "team-b"])
        // A string percent isn't a number, even with status "ok": skipped.
        #expect(s.readings == [
            SourceReading(provider: .go, fileKey: "team-a", window: .fiveHour, usedPercent: 40,
                          resetsAt: date("2026-11-22T14:00:00Z"),
                          observedAt: date("2026-11-22T11:59:00Z"), source: .ocgo),
        ])
    }

    @Test(arguments: [
        #""forced_account": "","#,
        #""forced_account": null,"#,
        #""forced_account": {"name": "team-a"},"#,
        "",
    ])
    func unsetForcedAccount(field: String) throws {
        let s = try parse("""
        { \(field) "accounts": [ { "name": "team-a", "available": true, "polled_at": "2026-11-22T11:59:00Z" } ] }
        """)
        #expect(s.routing?.forcedAccount == nil)
        #expect(account(s, "team-a")?.unavailable == [])
    }

    // MARK: E16, the source half

    @Test func e16Poll1150() async throws {
        let s = try await fetch("e16-1150.json", at: "2026-11-22T11:50:00Z")
        let t = date("2026-11-22T11:50:00Z")
        let reset = date("2026-11-22T12:00:00Z")
        #expect(Set(s.readings) == [
            SourceReading(provider: .go, fileKey: "team-a", window: .fiveHour, usedPercent: 60,
                          resetsAt: reset, observedAt: t, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-a", window: .weekly, usedPercent: 30,
                          resetsAt: reset, observedAt: t, source: .ocgo),
        ])
        #expect(s.readings.count == 2)
    }

    @Test func e16Poll1202() async throws {
        let s = try await fetch("e16-1202.json", at: "2026-11-22T12:02:00Z")
        // Rolling is a fresh reading taken after the 12:00 reset (95% left). Weekly is
        // status "error" with percent 0: no reading, so it can't pass as 100% left;
        // the ledger keeps 11:50's 30% for the hover.
        #expect(s.readings == [
            SourceReading(provider: .go, fileKey: "team-a", window: .fiveHour, usedPercent: 5,
                          resetsAt: date("2026-11-22T17:00:00Z"),
                          observedAt: date("2026-11-22T12:02:00Z"), source: .ocgo),
        ])
        #expect(account(s, "team-a")?.polledAt == date("2026-11-22T12:02:00Z"))
    }

    // MARK: Past reset

    @Test func pastResetWithEarlierPollIsNotReset() async throws {
        let s = try await fetch("past-reset.json", at: "2026-11-22T12:05:00Z")
        let rolling = try #require(reading(s, "team-a", .fiveHour))
        // Old percent, old time; no 0% made up for the 12:00 reset.
        #expect(rolling.usedPercent == 60)
        #expect(rolling.observedAt == date("2026-11-22T11:50:00Z"))
        #expect(rolling.resetsAt == date("2026-11-22T12:00:00Z"))
        #expect(rolling.observedAt < rolling.resetsAt!, "no proof of reset (Pool rule 3)")
        #expect(s.readings.filter { $0.window == .fiveHour }.count == 1)
        #expect(s.readings.allSatisfy { $0.observedAt == date("2026-11-22T11:50:00Z") })
        #expect(s.takenAt == date("2026-11-22T12:05:00Z"))
    }

    // MARK: poll_error

    @Test func pollErrorKeepsLastGoodReading() async throws {
        let s = try await fetch("poll-error.json")
        let lastGood = date("2026-11-22T11:40:00Z")

        let a = try #require(account(s, "team-a"))
        #expect(a.pollError == "usage poll: upstream returned 502")
        #expect(a.polledAt == lastGood)
        // The last good windows, with their old time: never stamped as "now".
        #expect(Set(s.readings.filter { $0.fileKey == "team-a" }) == [
            SourceReading(provider: .go, fileKey: "team-a", window: .fiveHour, usedPercent: 45,
                          resetsAt: date("2026-11-22T14:00:00Z"), observedAt: lastGood, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-a", window: .weekly, usedPercent: 20,
                          resetsAt: date("2026-11-26T09:00:00Z"), observedAt: lastGood, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-a", window: .monthly, usedPercent: 10,
                          resetsAt: date("2026-12-01T00:00:00Z"), observedAt: lastGood, source: .ocgo),
        ])

        // First poll failed: still unknown.
        #expect(account(s, "team-b")?.pollError == "usage poll: dial tcp: i/o timeout")
        #expect(account(s, "team-b")?.polledAt == nil)
        // Failed windows: no reading.
        #expect(account(s, "team-c")?.pollError == "usage poll: decode: unexpected EOF")
        #expect(s.readings.allSatisfy { $0.fileKey == "team-a" })
    }

    // MARK: status != "ok"

    @Test func onlyOkWindowsWithAPercentAreRead() async throws {
        let s = try await fetch("status-not-ok.json")
        #expect(s.readings == [
            SourceReading(provider: .go, fileKey: "team-a", window: .fiveHour, usedPercent: 30,
                          resetsAt: date("2026-11-22T14:00:00Z"),
                          observedAt: date("2026-11-22T11:59:00Z"), source: .ocgo),
        ])
        #expect(s.accounts.count == 2)
    }

    // MARK: Availability

    @Test func availabilityReasons() async throws {
        let s = try await fetch("availability.json")
        let expected: [(String, [Unavailability])] = [
            // "Usable now" follows `available`.
            ("ok-advisory-cooldown", []),
            ("exhausted", [.exhausted(until: date("2026-11-23T00:00:00Z"))]),
            ("cooling", [.coolingDown(until: date("2026-11-22T12:30:00Z"))]),
            ("both", [.exhausted(until: nil), .coolingDown(until: date("2026-11-22T12:20:00Z"))]),
            ("no-reason", [.upstreamUnavailable]),
            ("expired-cooldown", [.upstreamUnavailable]),
            ("zero-cooldown", []),
        ]
        #expect(s.accounts.map(\.fileKey) == expected.map(\.0))
        for (name, reasons) in expected {
            #expect(account(s, name)?.unavailable == reasons, "\(name)")
        }
        // Unavailable accounts still show their quota (Pool rule 4).
        #expect(s.readings.count == expected.count)
        #expect(reading(s, "exhausted", .fiveHour)?.usedPercent == 100)
    }

    @Test func wrongTypedFieldSkipsTheWholeWindow() throws {
        let s = try parse("""
        { "accounts": [
          { "name": "team-a", "polled_at": "2026-11-22T11:59:00Z", "windows": {
              "rolling": { "status": "ok", "percent": 40, "resets_at": 12345 },
              "weekly": { "status": "ok", "percent": true, "resets_at": "2026-11-26T09:00:00Z" },
              "monthly": { "status": 1, "percent": 10, "resets_at": "2026-12-01T00:00:00Z" } } },
          { "name": "team-b", "polled_at": "2026-11-22T11:59:00Z", "windows": {
              "rolling": { "status": "ok", "percent": 40, "resets_at": null },
              "weekly": { "status": "ok", "percent": 20 } } }
        ] }
        """)
        // team-a: each window has one wrong-typed field, so none gives a reading (a
        // 40% with no reset would replace the last good reading and lose its reset).
        // team-b: a null or missing resets_at is valid and means unset.
        let t = date("2026-11-22T11:59:00Z")
        #expect(Set(s.readings) == [
            SourceReading(provider: .go, fileKey: "team-b", window: .fiveHour, usedPercent: 40,
                          resetsAt: nil, observedAt: t, source: .ocgo),
            SourceReading(provider: .go, fileKey: "team-b", window: .weekly, usedPercent: 20,
                          resetsAt: nil, observedAt: t, source: .ocgo),
        ])
        #expect(s.readings.count == 2)
    }

    @Test func missingOptionalFieldsAreTolerated() throws {
        let s = try parse("""
        { "accounts": [ { "name": "team-a", "polled_at": "2026-11-22T11:59:00Z", "poll_error": null,
                          "windows": null } ] }
        """)
        #expect(s.readings.isEmpty)
        #expect(account(s, "team-a")?.unavailable == [])
        #expect(account(s, "team-a")?.pollError == nil)
    }
}

// MARK: Live fixture (P0.3)

private let liveOcgoFixture = "live/ocgo-status.json"

@Suite("T7 ocgo live fixture",
       .enabled(if: FileManager.default.fileExists(atPath: Fixtures.url(liveOcgoFixture).path),
                "Fixtures/live/ocgo-status.json is missing: P0.3 hasn't captured it yet"))
struct T7OcgoLiveFixtureTests {
    /// Checks the parse against the raw JSON read independently, since the live values
    /// aren't known in advance (EXPECTED.md covers the pooled numbers, in T10).
    @Test func parsesLiveStatus() throws {
        let data = try Fixtures.data(liveOcgoFixture)
        let takenAt = Date()
        let s = try OcgoStatusParser.snapshot(from: data, takenAt: takenAt).get()

        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawAccounts = try #require(raw["accounts"] as? [[String: Any]])
        #expect(!rawAccounts.isEmpty)
        #expect(s.accounts.map(\.fileKey) == rawAccounts.compactMap { $0["name"] as? String })

        let forced = (raw["forced_account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        #expect(s.routing?.forcedAccount?.identity == forced)

        let names = [("rolling", WindowKind.fiveHour), ("weekly", .weekly), ("monthly", .monthly)]
        for acct in rawAccounts {
            let name = try #require(acct["name"] as? String)
            let mine = s.readings.filter { $0.fileKey == name }
            let polledAt: Date
            switch Self.classify(acct["polled_at"]) {
            case .unset:
                #expect(mine.isEmpty, "\(name) was never polled")
                continue
            case .unparseable(let raw):
                Issue.record("\(name) polled_at \(String(describing: raw)) isn't a timestamp")
                continue
            case .set(let raw, let d):
                // A real timestamp must parse; otherwise the account would wrongly
                // read as never polled and give no readings.
                #expect(WireDate.parse(raw) != nil, "\(name) polled_at \(raw) doesn't parse")
                polledAt = d
            }
            #expect(mine.allSatisfy { Self.close($0.observedAt, polledAt) && $0.source == .ocgo && $0.provider == .go },
                    "\(name)")

            let windows = acct["windows"] as? [String: Any] ?? [:]
            var expected: [WindowKind: Double] = [:]
            for (key, kind) in names {
                guard let w = windows[key] as? [String: Any], Self.wellTyped(w),
                      w["status"] as? String == "ok", let p = Self.number(w["percent"])
                else { continue }
                expected[kind] = min(max(p, 0), 100)
                let r = mine.first { $0.window == kind }
                switch Self.classify(w["resets_at"]) {
                case .unset:
                    #expect(r != nil && r?.resetsAt == nil, "\(name) \(key) has an unset reset")
                case .unparseable(let raw):
                    Issue.record("\(name) \(key) resets_at \(String(describing: raw)) isn't a timestamp")
                case .set(let raw, let reset):
                    #expect(WireDate.parse(raw) != nil, "\(name) \(key) resets_at \(raw) doesn't parse")
                    #expect(r?.resetsAt.map { Self.close($0, reset) } == true, "\(name) \(key) resetsAt")
                }
            }
            #expect(Dictionary(uniqueKeysWithValues: mine.map { ($0.window, $0.usedPercent) }) == expected, "\(name)")
        }
    }

    enum RawTime {
        /// Missing, null, empty, epoch 0 or Go's zero time (plan.md "unset").
        case unset
        case set(String, Date)
        case unparseable(Any)
    }

    /// Classifies a raw JSON timestamp from its independently parsed instant, not by
    /// WireDate and not by its text.
    static func classify(_ value: Any?) -> RawTime {
        guard let value, !(value is NSNull) else { return .unset }
        guard let s = value as? String else { return .unparseable(value) }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .unset }
        guard let d = referenceDate(trimmed) else { return .unparseable(s) }
        if d.timeIntervalSince1970 == 0 || d == goZeroTime { return .unset }
        return .set(s, d)
    }

    static let goZeroTime = referenceDate("0001-01-01T00:00:00Z")!

    /// RFC 3339 parse independent of WireDate, keeping the whole fraction: the
    /// seconds part goes through ISO8601DateFormatter, the fraction digits are added
    /// exactly.
    static func referenceDate(_ s: String) -> Date? {
        var text = s
        var fraction = Decimal(0)
        if let dot = s.firstIndex(of: ".") {
            let digits = s[s.index(after: dot)...].prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Decimal(string: "0." + digits) else { return nil }
            fraction = value
            text = String(s[..<dot]) + String(s[s.index(dot, offsetBy: 1 + digits.count)...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let whole = f.date(from: text) else { return nil }
        return whole.addingTimeInterval(NSDecimalNumber(decimal: fraction).doubleValue)
    }

    /// A JSON number, excluding booleans (JSONSerialization bridges them to NSNumber).
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// Mirrors the source's rule that a window with any wrong-typed field is skipped;
    /// missing or null fields are fine.
    static func wellTyped(_ w: [String: Any]) -> Bool {
        func absent(_ v: Any?) -> Bool { v == nil || v is NSNull }
        return (absent(w["status"]) || w["status"] is String)
            && (absent(w["percent"]) || number(w["percent"]) != nil)
            && (absent(w["resets_at"]) || w["resets_at"] is String)
    }

    /// Double resolution at today's dates is about 0.2 microseconds.
    static func close(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 0.000_01
    }
}
