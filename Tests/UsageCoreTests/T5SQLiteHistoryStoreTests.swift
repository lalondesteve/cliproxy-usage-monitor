import Foundation
import Testing
import UsageCore

/// T5: the SQLite history store, against a temporary file database.
@Suite("T5 SQLite history store")
struct T5SQLiteHistoryStoreTests {
    let db = T5TempDatabase()
    let now = date("2026-11-22T12:00:00Z")
    let day: TimeInterval = 24 * 3600

    /// Opens the database file without the on-open prune unless a clock is given.
    func open(now clock: Date? = nil) throws -> SQLiteHistoryStore {
        if let clock {
            return try SQLiteHistoryStore(path: db.path, now: FixedNowProvider(clock))
        }
        return try SQLiteHistoryStore(path: db.path, retention: nil)
    }

    func reading(_ provider: Provider = .claude, file: String = "claude-1a2b3c4d-x@example.com.json",
                 _ window: WindowKind = .fiveHour, used: Double = 30, resets: Date? = nil,
                 at observedAt: Date, _ source: ReadingSource = .passive) -> SourceReading {
        SourceReading(provider: provider, fileKey: file, window: window, usedPercent: used,
                      resetsAt: resets, observedAt: observedAt, source: source)
    }

    // MARK: Acceptance

    @Test func readingsAndMarksSurviveReopen() throws {
        let r1 = reading(used: 40, resets: date("2026-11-22T14:10:00Z"), at: now.addingTimeInterval(-600))
        let r2 = reading(.codex, file: "codex-a.json", .weekly, used: 12,
                         resets: date("2026-11-25T00:00:00Z"), at: now, .forkPoller)
        let marks = [CounterMark(fileKey: "claude-1a2b3c4d-x@example.com.json", at: now, value: 1500)]
        do {
            let store = try open()
            try store.append([r1, r2])
            try store.appendCounterMarks(marks)
            store.close()
        }

        let store = try open()
        #expect(try store.readings(fileKeys: [r1.fileKey, r2.fileKey], nil,
                                   from: now.addingTimeInterval(-day), to: now) == [r1, r2])
        #expect(Set(try store.latestReadings()) == [r1, r2])
        #expect(try store.counterMarks(since: now.addingTimeInterval(-day)) == marks)
    }

    @Test func pruneDropsA31DayRowAndKeepsA29DayRow() throws {
        let store = try open()
        let old = now.addingTimeInterval(-31 * day)
        let recent = now.addingTimeInterval(-29 * day)
        try store.append([reading(at: old), reading(at: recent)])
        try store.appendCounterMarks([CounterMark(fileKey: "f", at: old, value: 1),
                                      CounterMark(fileKey: "f", at: recent, value: 2)])
        try store.recordGap(from: old, to: old.addingTimeInterval(3600))
        try store.recordGap(from: recent, to: recent.addingTimeInterval(3600))

        try store.prune(olderThan: now.addingTimeInterval(-30 * day))

        let all = try store.readings(fileKeys: [reading(at: now).fileKey], nil,
                                     from: .distantPast, to: .distantFuture)
        #expect(all.map(\.observedAt) == [recent])
        #expect(try store.counterMarks(since: .distantPast).map(\.at) == [recent])
        #expect(try store.gaps(since: .distantPast).map(\.start) == [recent])
    }

    @Test func pruneRunsOnOpen() throws {
        let old = reading(at: now.addingTimeInterval(-31 * day))
        let recent = reading(at: now.addingTimeInterval(-29 * day))
        do {
            let store = try open()
            try store.append([old, recent])
            store.close()
        }

        let store = try open(now: now)
        #expect(try store.readings(fileKeys: [old.fileKey], nil, from: .distantPast,
                                   to: .distantFuture) == [recent])
    }

    @Test func sameForkHistoryTwiceGivesOneRow() throws {
        let history = [
            reading(.claude, .fiveHour, used: 20, at: date("2026-11-22T11:00:00.5Z"), .forkPoller),
            reading(.claude, .weekly, used: 8, at: date("2026-11-22T11:00:00.5Z"), .forkPoller),
        ]
        do {
            let store = try open()
            try store.append(history)
            try store.append(history)
            store.close()
        }

        let store = try open()
        let stored = try store.readings(fileKeys: [history[0].fileKey], nil,
                                        from: .distantPast, to: .distantFuture)
        #expect(stored.count == 2)
        #expect(Set(stored) == Set(history))
        #expect(try store.readings(fileKeys: [history[0].fileKey], .fiveHour,
                                   from: .distantPast, to: .distantFuture) == [history[0]])
    }

    @Test func passiveAndForkReadingsWithTheSameKeyBothSurviveReopen() throws {
        let passive = reading(used: 30, at: now, .passive)
        let fork = reading(used: 31, at: now, .forkPoller)
        do {
            let store = try open()
            try store.append([passive, fork])
            store.close()
        }

        let store = try open()
        #expect(Set(try store.readings(fileKeys: [passive.fileKey], .fiveHour,
                                       from: now, to: now)) == [passive, fork])
        #expect(Set(try store.latestReadings()) == [passive, fork])
    }

    @Test func aliasesSurviveReopen() throws {
        let c1 = AccountID(provider: .claude, identity: "1a2b3c4d")
        let c2 = AccountID(provider: .claude, identity: "x@example.com")
        let x1 = AccountID(provider: .codex, identity: "chatgpt-acc-1")
        let g1 = AccountID(provider: .go, identity: "team-a")
        do {
            let store = try open()
            // plan.md: `claude-1`, ... in first-sight order; Go keeps its name (`team-a`).
            #expect(try store.alias(for: c1) == ("claude-1", 0))
            #expect(try store.alias(for: c2) == ("claude-2", 1))
            #expect(try store.alias(for: x1) == ("codex-1", 0))
            #expect(try store.alias(for: g1) == ("team-a", 0))
            #expect(try store.alias(for: c1) == ("claude-1", 0))
            store.close()
        }

        let store = try open()
        #expect(try store.alias(for: c2) == ("claude-2", 1))
        #expect(try store.alias(for: c1) == ("claude-1", 0))
        #expect(try store.alias(for: g1) == ("team-a", 0))
        #expect(try store.alias(for: AccountID(provider: .claude, identity: "9f9f9f9f")) == ("claude-3", 2))
        #expect(try store.alias(for: x1) == ("codex-1", 0))
    }

    @Test func lastSnapshotsSurviveReopen() throws {
        let t = date("2026-11-22T11:58:03.123456Z")
        let claude = AccountID(provider: .claude, identity: "1a2b3c4d")
        let teamB = AccountID(provider: .go, identity: "team-b")
        let first = SourceSnapshot(source: .cliproxy, takenAt: t.addingTimeInterval(-60), accounts: [],
                                   readings: [], unclassified: [], routing: nil)
        let cliproxy = SourceSnapshot(
            source: .cliproxy, takenAt: t,
            accounts: [AccountSnapshot(
                id: claude, fileKey: "claude-1a2b3c4d-x@example.com.json", email: "x@example.com",
                enabled: true, unavailable: [.upstreamUnavailable], requestCounter: 1500,
                routing: AccountRouting(priority: 0, weight: 1), polledAt: nil, pollError: nil)],
            readings: [reading(used: 30, resets: t.addingTimeInterval(3600), at: t)],
            unclassified: [UnclassifiedReading(provider: .codex, fileKey: "codex-a.json", lengthSeconds: nil,
                                               usedPercent: 4, resetsAt: nil, observedAt: t)],
            routing: RoutingConfig(strategy: .fillFirst, sessionAffinity: true, forcedAccount: nil))
        let ocgo = SourceSnapshot(
            source: .ocgo, takenAt: t,
            accounts: [
                AccountSnapshot(id: AccountID(provider: .go, identity: "team-a"), fileKey: "team-a",
                                email: nil, enabled: true, unavailable: [.notForcedAccount],
                                requestCounter: nil, routing: nil, polledAt: nil, pollError: nil),
                AccountSnapshot(id: teamB, fileKey: "team-b", email: nil, enabled: true,
                                unavailable: [.coolingDown(until: t.addingTimeInterval(2400))],
                                requestCounter: nil, routing: nil, polledAt: t, pollError: "boom"),
            ],
            readings: [], unclassified: [],
            routing: RoutingConfig(strategy: .mostHeadroom, sessionAffinity: false, forcedAccount: teamB))
        do {
            let store = try open()
            try store.saveLastSnapshot(first)
            try store.saveLastSnapshot(ocgo)
            try store.saveLastSnapshot(cliproxy)
            store.close()
        }

        let store = try open()
        let restored = try store.lastSnapshots()
        #expect(restored.count == 2)
        #expect(restored.first { $0.source == .cliproxy } == cliproxy)
        #expect(restored.first { $0.source == .ocgo } == ocgo)
    }

    /// A late snapshot (12:04 arriving after 12:05) or a second one with the same
    /// `takenAt` doesn't replace the stored one; a newer one does.
    @Test func olderOrEqualSnapshotDoesNotReplaceNewer() throws {
        func snapshot(_ at: String, counter: Int) -> SourceSnapshot {
            SourceSnapshot(
                source: .cliproxy, takenAt: date(at),
                accounts: [AccountSnapshot(
                    id: AccountID(provider: .claude, identity: "1a2b3c4d"), fileKey: "a.json",
                    email: nil, enabled: true, unavailable: [], requestCounter: counter,
                    routing: nil, polledAt: nil, pollError: nil)],
                readings: [], unclassified: [], routing: nil)
        }
        let at1205 = snapshot("2026-11-22T12:05:00Z", counter: 1502)
        do {
            let store = try open()
            try store.saveLastSnapshot(at1205)
            try store.saveLastSnapshot(snapshot("2026-11-22T12:04:00Z", counter: 1500))
            try store.saveLastSnapshot(snapshot("2026-11-22T12:05:00Z", counter: 9999))
            #expect(try store.lastSnapshots() == [at1205])
            store.close()
        }

        let store = try open()
        #expect(try store.lastSnapshots() == [at1205])
        let at1206 = snapshot("2026-11-22T12:06:00Z", counter: 1510)
        try store.saveLastSnapshot(at1206)
        #expect(try store.lastSnapshots() == [at1206])
    }

    @Test func gapsSurviveReopen() throws {
        let sleep = DateInterval(start: date("2026-11-22T13:00:00Z"), end: date("2026-11-22T14:00:00Z"))
        let offline = DateInterval(start: date("2026-11-21T22:00:00.25Z"), end: date("2026-11-22T08:00:00Z"))
        do {
            let store = try open()
            try store.recordGap(from: sleep.start, to: sleep.end)
            try store.recordGap(from: offline.start, to: offline.end)
            try store.recordGap(from: sleep.start, to: sleep.end)
            store.close()
        }

        let store = try open()
        #expect(try store.gaps(since: .distantPast) == [offline, sleep])
        #expect(try store.gaps(since: date("2026-11-22T09:00:00Z")) == [sleep])
    }

    @Test func forkProviderStatesSurviveReopen() throws {
        do {
            let store = try open()
            #expect(try store.forkProviderStates() == [:])
            try store.saveForkProviderStates([.claude: .served, .codex: .served])
            try store.saveForkProviderStates([.claude: .served, .codex: .paused])
            store.close()
        }

        let store = try open()
        #expect(try store.forkProviderStates() == [.claude: .served, .codex: .paused])
    }

    // MARK: Round trips

    @Test func nilResetsAtRoundTripsAsNil() throws {
        let r = reading(resets: nil, at: now, .forkPoller)
        do {
            let store = try open()
            try store.append([r])
            store.close()
        }

        let store = try open()
        let latest = try store.latestReadings()
        #expect(latest == [r])
        #expect(latest.first?.resetsAt == nil)
    }

    /// Dates are stored as the Double a `Date` holds, so sub-second digits survive
    /// exactly, and two observations a microsecond apart stay two rows.
    @Test func subSecondDatesRoundTripExactly() throws {
        let a = Date(timeIntervalSince1970: 1_764_000_000.123456789)
        let b = a.addingTimeInterval(0.000_001)
        let ra = reading(used: 10, resets: a.addingTimeInterval(3600.5), at: a, .forkPoller)
        let rb = reading(used: 11, at: b, .forkPoller)
        do {
            let store = try open()
            try store.append([ra, rb])
            try store.append([ra])
            store.close()
        }

        let store = try open()
        let stored = try store.readings(fileKeys: [ra.fileKey], .fiveHour, from: a, to: b)
        #expect(stored == [ra, rb])
        #expect(stored.first?.observedAt == a)
        #expect(stored.first?.resetsAt == a.addingTimeInterval(3600.5))
        #expect(try store.lastObservation(.claude, source: .forkPoller) == b)
    }

    // MARK: Queries

    @Test func latestReadingsKeepsTheNewestPerKey() throws {
        // E7: snapshot 1 has 5h 30% and 7d 10%; snapshot 2 has 7d 12% only.
        let t1 = date("2026-11-22T11:00:00Z")
        let t2 = date("2026-11-22T11:01:00Z")
        let store = try open()
        try store.append([reading(.claude, .fiveHour, used: 30, at: t1), reading(.claude, .weekly, used: 10, at: t1)])
        try store.append([reading(.claude, .weekly, used: 12, at: t2)])

        #expect(Set(try store.latestReadings()) == [reading(.claude, .fiveHour, used: 30, at: t1),
                                                    reading(.claude, .weekly, used: 12, at: t2)])
    }

    @Test func lastObservationIsPerProviderAndSource() throws {
        let store = try open()
        #expect(try store.lastObservation(.claude, source: .forkPoller) == nil)
        try store.append([
            reading(.claude, at: date("2026-11-22T09:59:00Z"), .forkPoller),
            reading(.claude, at: date("2026-11-22T09:00:00Z"), .forkPoller),
            reading(.claude, at: date("2026-11-22T13:00:00Z"), .passive),
            reading(.codex, file: "codex-a.json", at: date("2026-11-22T09:50:00Z"), .forkPoller),
        ])

        #expect(try store.lastObservation(.claude, source: .forkPoller) == date("2026-11-22T09:59:00Z"))
        #expect(try store.lastObservation(.claude, source: .passive) == date("2026-11-22T13:00:00Z"))
        #expect(try store.lastObservation(.codex, source: .forkPoller) == date("2026-11-22T09:50:00Z"))
        #expect(try store.lastObservation(.go, source: .ocgo) == nil)
    }

    @Test func readingsFilterByFileWindowAndInclusiveRange() throws {
        let store = try open()
        let t0 = date("2026-11-22T10:00:00Z")
        let inRange = [
            reading(file: "a.json", .fiveHour, at: t0),
            reading(file: "a.json", .fiveHour, at: t0.addingTimeInterval(900)),
        ]
        try store.append(inRange + [
            reading(file: "a.json", .fiveHour, at: t0.addingTimeInterval(901)),
            reading(file: "a.json", .weekly, at: t0),
            reading(file: "b.json", .fiveHour, at: t0),
        ])

        #expect(try store.readings(fileKeys: ["a.json"], .fiveHour, from: t0,
                                   to: t0.addingTimeInterval(900)) == inRange)
        #expect(try store.readings(fileKeys: ["a.json", "b.json"], nil, from: t0, to: t0).count == 3)
        #expect(try store.readings(fileKeys: [], nil, from: .distantPast, to: .distantFuture) == [])
    }

    @Test func counterMarksAreIdempotentAndFilteredBySince() throws {
        let store = try open()
        let t1 = date("2026-11-22T11:50:00Z")
        let t2 = date("2026-11-22T12:05:00Z")
        let marks = [CounterMark(fileKey: "a.json", at: t1, value: 1500),
                     CounterMark(fileKey: "a.json", at: t2, value: 1500)]
        try store.appendCounterMarks(marks)
        try store.appendCounterMarks(marks)

        #expect(try store.counterMarks(since: t1) == marks)
        #expect(try store.counterMarks(since: t1.addingTimeInterval(1)) == [marks[1]])
    }

    // MARK: Safety

    @Test func concurrentCallersGetDistinctAliasesAndNoLostWrites() throws {
        let store = try open()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            #expect(throws: Never.self) {
                _ = try store.alias(for: AccountID(provider: .codex, identity: "acc-\(i)"))
                try store.append([reading(.codex, file: "f\(i).json", at: now, .passive)])
            }
        }

        let indexes = try (0..<40).map {
            try store.alias(for: AccountID(provider: .codex, identity: "acc-\($0)")).colorIndex
        }
        #expect(Set(indexes) == Set(0..<40))
        #expect(try store.latestReadings().count == 40)
    }

    @Test func invalidGapThrows() throws {
        let store = try open()
        #expect(throws: HistoryStoreError.invalidGap) {
            try store.recordGap(from: now, to: now.addingTimeInterval(-1))
        }
    }

    @Test func callsAfterCloseThrow() throws {
        let store = try open()
        store.close()
        #expect(throws: HistoryStoreError.closed) { try store.latestReadings() }
    }
}
