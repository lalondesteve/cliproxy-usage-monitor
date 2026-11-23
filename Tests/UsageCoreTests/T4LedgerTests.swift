import Foundation
import Testing
import UsageCore

// Expected values come from docs/implementation-plan.md "Worked examples" (E5 to E5e,
// E7, E14, E16) and the T4 acceptance list, not from running the ledger.

private func t(_ hhmm: String) -> Date { date("2026-11-22T\(hhmm):00Z") }

private func cred(_ identity: String, file: String, email: String? = nil, enabled: Bool = true,
                  unavailable: [Unavailability] = [], counter: Int? = 0,
                  routing: AccountRouting? = nil) -> AccountSnapshot {
    cred(.claude, identity, file: file, email: email, enabled: enabled, unavailable: unavailable,
         counter: counter, routing: routing)
}

private func cred(_ provider: Provider, _ identity: String, file: String,
                  email: String? = nil, enabled: Bool = true, unavailable: [Unavailability] = [],
                  counter: Int? = 0, routing: AccountRouting? = nil) -> AccountSnapshot {
    AccountSnapshot(id: AccountID(provider: provider, identity: identity), fileKey: file, email: email,
                    enabled: enabled, unavailable: unavailable, requestCounter: counter,
                    routing: routing, polledAt: nil, pollError: nil)
}

private func goAccount(_ name: String, polledAt: Date?, unavailable: [Unavailability] = []) -> AccountSnapshot {
    AccountSnapshot(id: AccountID(provider: .go, identity: name), fileKey: name, email: nil,
                    enabled: true, unavailable: unavailable, requestCounter: nil, routing: nil,
                    polledAt: polledAt, pollError: nil)
}

private func reading(_ file: String, _ w: WindowKind, used: Double, resets: Date?, at: Date,
                     source: ReadingSource = .passive) -> SourceReading {
    reading(.claude, file, w, used: used, resets: resets, at: at, source: source)
}

private func reading(_ provider: Provider, _ file: String, _ w: WindowKind, used: Double,
                     resets: Date?, at: Date, source: ReadingSource = .passive) -> SourceReading {
    SourceReading(provider: provider, fileKey: file, window: w, usedPercent: used, resetsAt: resets,
                  observedAt: at, source: source)
}

private func cliproxy(_ at: Date, _ accounts: [AccountSnapshot], readings: [SourceReading] = [],
                      unclassified: [UnclassifiedReading] = [],
                      routing: RoutingConfig? = nil) -> SourceSnapshot {
    SourceSnapshot(source: .cliproxy, takenAt: at, accounts: accounts, readings: readings,
                   unclassified: unclassified, routing: routing)
}

private func ocgo(_ at: Date, _ accounts: [AccountSnapshot], readings: [SourceReading] = [],
                  forced: String? = nil) -> SourceSnapshot {
    SourceSnapshot(source: .ocgo, takenAt: at, accounts: accounts, readings: readings, unclassified: [],
                   routing: RoutingConfig(strategy: .mostHeadroom, sessionAffinity: false,
                                          forcedAccount: forced.map { AccountID(provider: .go, identity: $0) }))
}

private let idA = AccountID(provider: .claude, identity: "aaaa0001")
private let fileA = "claude-aaaa0001-a@example.com.json"
private let fileA2 = "claude-aaaa0001-a2@example.com.json"

@Suite("T4 ledger: reset proof by counters (E5 to E5e)")
struct T4CounterProofTests {
    let store = T4FakeHistoryStore()

    /// A used 40, resets 12:00; listings at 11:50 and 12:05 with the given counters per file.
    private func ledger(before: [String: Int], after: [String: Int]) throws -> Ledger {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let r = reading(fileA, .fiveHour, used: 40, resets: t("12:00"), at: t("11:45"))
        for (at, counters) in [(t("11:50"), before), (t("12:05"), after)] {
            let accounts = counters.keys.sorted().map { cred("aaaa0001", file: $0, counter: counters[$0]) }
            try t4PersistAndApply(cliproxy(at, accounts, readings: [r]), store: store, ledger: ledger)
        }
        return ledger
    }

    @Test func e5UnchangedCounterProvesReset() throws {
        let ledger = try ledger(before: [fileA: 1500], after: [fileA: 1500])
        #expect(ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func e5bUseAfterListingGivesNoProof() throws {
        let ledger = try ledger(before: [fileA: 1500], after: [fileA: 1502])
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
        // The old reading stays for the hover: 60% left, observed 11:45.
        let latest = try #require(ledger.latest(idA, .fiveHour))
        #expect(latest.reading.usedPercent == 40)
        #expect(latest.reading.observedAt == t("11:45"))
        #expect(latest.account == idA)
    }

    @Test func e5cCounterDropGivesNoProof() throws {
        let ledger = try ledger(before: [fileA: 1500], after: [fileA: 20])
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func e5dRestartHiddenBySumGivesNoProof() throws {
        let ledger = try ledger(before: [fileA: 100, fileA2: 10], after: [fileA: 0, fileA2: 110])
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func twoUnchangedFilesProveReset() throws {
        let ledger = try ledger(before: [fileA: 100, fileA2: 10], after: [fileA: 100, fileA2: 10])
        #expect(ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func e5eFileJoiningGivesNoProof() throws {
        let ledger = try ledger(before: [fileA: 1500], after: [fileA: 1500, fileA2: 0])
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func fileLeavingGivesNoProof() throws {
        let ledger = try ledger(before: [fileA: 1500, fileA2: 7], after: [fileA: 1500])
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func noListingBeforeResetGivesNoProof() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        try t4PersistAndApply(cliproxy(t("12:05"), [cred("aaaa0001", file: fileA, counter: 1500)],
                                       readings: [reading(fileA, .fiveHour, used: 40, resets: t("12:00"),
                                                          at: t("11:45"))]),
                              store: store, ledger: ledger)
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func noListingAfterResetGivesNoProof() throws {
        let ledger = try ledger(before: [fileA: 1500], after: [fileA: 1500])
        #expect(!ledger.resetProven(idA, .fiveHour, resetAt: t("12:10")))
    }

    @Test func proofUsesTheLastListingBeforeTheReset() throws {
        // Used at 11:55 (1500 -> 1501), then idle across the 12:00 reset.
        let ledger = Ledger(store: store, settings: PoolSettings())
        for (at, value) in [(t("11:50"), 1500), (t("11:55"), 1501), (t("12:05"), 1501)] {
            try t4PersistAndApply(cliproxy(at, [cred("aaaa0001", file: fileA, counter: value)]),
                                  store: store, ledger: ledger)
        }
        #expect(ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
        // A change in between breaks it: 1500 at 11:50, 1503 at 12:01, back to 1500 at 12:05.
        let other = Ledger(store: T4FakeHistoryStore(), settings: PoolSettings())
        for (at, value) in [(t("11:50"), 1500), (t("12:01"), 1503), (t("12:05"), 1500)] {
            other.apply(cliproxy(at, [cred("aaaa0001", file: fileA, counter: value)]))
        }
        #expect(!other.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func proofIsPerAccount() throws {
        let idB = AccountID(provider: .claude, identity: "bbbb0002")
        let ledger = Ledger(store: store, settings: PoolSettings())
        for (at, b) in [(t("11:50"), 300), (t("12:05"), 305)] {
            ledger.apply(cliproxy(at, [cred("aaaa0001", file: fileA, counter: 1500),
                                       cred("bbbb0002", file: "claude-bbbb0002-b@example.com.json", counter: b)]))
        }
        #expect(ledger.resetProven(idA, .weekly, resetAt: t("12:00")))
        #expect(!ledger.resetProven(idB, .weekly, resetAt: t("12:00")))
    }

    /// A request that finished at 12:00:01 still reports the window that reset at
    /// 12:00 (used 90). Observed after the reset, but it isn't a reading of the new
    /// window, so only the counters can prove the reset.
    @Test func readingStillCarryingTheOldResetIsNoProof() throws {
        let late = SourceReading(provider: .claude, fileKey: fileA, window: .fiveHour, usedPercent: 90,
                                 resetsAt: t("12:00"), observedAt: date("2026-11-22T12:00:01Z"),
                                 source: .passive)
        func ledger(counterAfter: Int) -> Ledger {
            let ledger = Ledger(store: T4FakeHistoryStore(), settings: PoolSettings())
            ledger.apply(cliproxy(t("11:50"), [cred("aaaa0001", file: fileA, counter: 1500)],
                                  readings: [reading(fileA, .fiveHour, used: 40, resets: t("12:00"),
                                                     at: t("11:45"))]))
            ledger.apply(cliproxy(t("12:05"), [cred("aaaa0001", file: fileA, counter: counterAfter)],
                                  readings: [late]))
            return ledger
        }
        let used = ledger(counterAfter: 1501)
        #expect(used.latest(idA, .fiveHour)?.reading == late)
        #expect(!used.resetProven(idA, .fiveHour, resetAt: t("12:00")))
        // With unchanged counters the counter proof still applies.
        #expect(ledger(counterAfter: 1500).resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    /// Codex `Reset-After-Seconds: 0` with no `Reset-At` gives resetsAt == observedAt:
    /// the old window ending, not a new one.
    @Test func readingThatEndsAsObservedIsNoProof() {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let codexFile = "codex-user-1@example.com-plus.json"
        let codex = AccountID(provider: .codex, identity: "chatgpt-acct-7f3e")
        let observed = date("2026-11-22T12:00:01Z")
        ledger.apply(cliproxy(t("12:05"), [cred(.codex, "chatgpt-acct-7f3e", file: codexFile, counter: nil)],
                              readings: [reading(.codex, codexFile, .fiveHour, used: 100, resets: observed,
                                                 at: observed)]))
        #expect(ledger.latest(codex, .fiveHour)?.reading.observedAt == observed)
        #expect(!ledger.resetProven(codex, .fiveHour, resetAt: t("12:00")))
    }

    @Test func freshReadingWithUnsetResetProves() {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(cliproxy(t("12:05"), [cred("aaaa0001", file: fileA, counter: nil)],
                              readings: [reading(fileA, .weekly, used: 0, resets: nil, at: t("12:01"))]))
        #expect(ledger.resetProven(idA, .weekly, resetAt: t("12:00")))
    }

    /// fileA2 leaves A's set across the reset. After a relaunch the ledger no longer
    /// knows whose file fileA2 was, so it must still deny the proof.
    @Test func fileLeavingAcrossResetGivesNoProofAfterRestore() throws {
        let live = Ledger(store: store, settings: PoolSettings())
        try t4PersistAndApply(cliproxy(t("11:50"), [cred("aaaa0001", file: fileA, counter: 1500),
                                                    cred("aaaa0001", file: fileA2, counter: 7)]),
                              store: store, ledger: live)
        try t4PersistAndApply(cliproxy(t("12:05"), [cred("aaaa0001", file: fileA, counter: 1500)]),
                              store: store, ledger: live)
        #expect(!live.resetProven(idA, .fiveHour, resetAt: t("12:00")))

        let restored = Ledger(store: store, settings: PoolSettings())
        try restored.restore()
        #expect(!restored.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }

    @Test func fileOfAnotherAccountDoesNotDenyTheProof() {
        // B's file leaves the list across the reset. The ledger saw it as B's, so A's
        // proof holds.
        let ledger = Ledger(store: store, settings: PoolSettings())
        let fileB = "claude-bbbb0002-b@example.com.json"
        ledger.apply(cliproxy(t("11:50"), [cred("aaaa0001", file: fileA, counter: 1500),
                                           cred("bbbb0002", file: fileB, counter: 1)]))
        ledger.apply(cliproxy(t("12:05"), [cred("aaaa0001", file: fileA, counter: 1500)]))
        #expect(ledger.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }
}

@Suite("T4 ledger: readings")
struct T4ReadingTests {
    let store = T4FakeHistoryStore()

    @Test func e7MissingWindowKeepsEarlierReading() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(cliproxy(t("11:00"), [cred("aaaa0001", file: fileA)], readings: [
            reading(fileA, .fiveHour, used: 30, resets: t("15:00"), at: t("11:00")),
            reading(fileA, .weekly, used: 10, resets: t("23:00"), at: t("11:00")),
        ]))
        ledger.apply(cliproxy(t("11:10"), [cred("aaaa0001", file: fileA)], readings: [
            reading(fileA, .weekly, used: 12, resets: t("23:00"), at: t("11:10")),
        ]))
        let fiveHour = try #require(ledger.latest(idA, .fiveHour))
        #expect(fiveHour.reading.usedPercent == 30)
        #expect(fiveHour.reading.observedAt == t("11:00"))
        #expect(ledger.latest(idA, .weekly)?.reading.usedPercent == 12)
    }

    @Test func olderReadingDoesNotReplaceNewer() {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(cliproxy(t("11:00"), [cred("aaaa0001", file: fileA)], readings: [
            reading(fileA, .weekly, used: 12, resets: nil, at: t("11:10")),
        ]))
        ledger.apply(readings: [reading(fileA, .weekly, used: 10, resets: nil, at: t("11:05"), source: .forkPoller)])
        #expect(ledger.latest(idA, .weekly)?.reading.usedPercent == 12)
    }

    @Test func newestReadingAcrossAnAccountsFilesWins() {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(cliproxy(t("11:00"), [cred("aaaa0001", file: fileA), cred("aaaa0001", file: fileA2)],
                              readings: [reading(fileA, .weekly, used: 20, resets: nil, at: t("10:50")),
                                         reading(fileA2, .weekly, used: 22, resets: nil, at: t("10:55"))]))
        #expect(ledger.latest(idA, .weekly)?.reading.fileKey == fileA2)
        #expect(ledger.latest(idA, .weekly)?.reading.usedPercent == 22)
    }

    @Test func identicalReadingsFromTwoFilesPickTheLowestFileKey() {
        let a = reading(fileA, .weekly, used: 20, resets: t("23:00"), at: t("10:50"))
        let a2 = reading(fileA2, .weekly, used: 20, resets: t("23:00"), at: t("10:50"))
        let creds = [cred("aaaa0001", file: fileA), cred("aaaa0001", file: fileA2)]
        let expected = min(fileA, fileA2)
        for order in [[a, a2], [a2, a]] {
            let ledger = Ledger(store: T4FakeHistoryStore(), settings: PoolSettings())
            ledger.apply(cliproxy(t("11:00"), creds, readings: order))
            #expect(ledger.latest(idA, .weekly)?.reading.fileKey == expected)
        }
    }

    @Test func e16OcgoProofIsAFreshOkReadingNotPolledAt() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let team = AccountID(provider: .go, identity: "team-a")
        ledger.apply(ocgo(t("11:50"), [goAccount("team-a", polledAt: t("11:50"))], readings: [
            reading(.go, "team-a", .fiveHour, used: 60, resets: t("12:00"), at: t("11:50"), source: .ocgo),
            reading(.go, "team-a", .weekly, used: 30, resets: t("12:00"), at: t("11:50"), source: .ocgo),
        ]))
        // 12:02: rolling ok at 5%; weekly status "error", so the source emits no weekly reading.
        ledger.apply(ocgo(t("12:02"), [goAccount("team-a", polledAt: t("12:02"))], readings: [
            reading(.go, "team-a", .fiveHour, used: 5, resets: t("17:00"), at: t("12:02"), source: .ocgo),
        ]))

        let rolling = try #require(ledger.latest(team, .fiveHour))
        #expect(100 - rolling.reading.usedPercent == 95)
        #expect(ledger.resetProven(team, .fiveHour, resetAt: t("12:00")))

        let weekly = try #require(ledger.latest(team, .weekly))
        #expect(100 - weekly.reading.usedPercent == 70)
        #expect(weekly.reading.observedAt == t("11:50"))
        #expect(!ledger.resetProven(team, .weekly, resetAt: t("12:00")))
    }

    @Test func unknownFileKeyIgnoredUntilCredentialAppears() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(cliproxy(t("11:00"), [cred("aaaa0001", file: fileA)]))
        let stray = "claude-cccc0003-c@example.com.json"
        let idC = AccountID(provider: .claude, identity: "cccc0003")
        try t4PersistAndApply(readings: [reading(stray, .weekly, used: 44, resets: nil, at: t("11:01"),
                                                 source: .forkPoller)],
                              store: store, ledger: ledger)

        #expect(ledger.accounts.map(\.id) == [idA])
        #expect(ledger.latest(idA, .weekly) == nil)
        #expect(ledger.latest(idC, .weekly) == nil)

        ledger.apply(cliproxy(t("11:02"), [cred("aaaa0001", file: fileA), cred("cccc0003", file: stray)]))
        #expect(ledger.latest(idC, .weekly)?.reading.usedPercent == 44)
        #expect(ledger.latest(idA, .weekly) == nil)
    }

    @Test func forkCurrentJoinsCodexByChatgptAccountID() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        // T6 sets a Codex credential's identity to its chatgpt_account_id; the fork's
        // account.id is the credential's fileKey.
        let codexFile = "codex-user-1@example.com-plus.json"
        let codex = AccountID(provider: .codex, identity: "chatgpt-acct-7f3e")
        ledger.apply(cliproxy(t("11:00"), [cred(.codex, "chatgpt-acct-7f3e", file: codexFile,
                                                email: "user-1@example.com")]))
        try t4PersistAndApply(readings: [
            reading(.codex, codexFile, .weekly, used: 18, resets: t("23:00"), at: t("10:58"), source: .forkPoller),
            reading(.codex, "codex-gone@example.com.json", .weekly, used: 90, resets: nil, at: t("10:58"),
                    source: .forkPoller),
        ], store: store, ledger: ledger)

        let joined = try #require(ledger.latest(codex, .weekly))
        #expect(joined.account == codex)
        #expect(joined.reading.usedPercent == 18)
        #expect(joined.reading.source == .forkPoller)
        // The unlisted fileKey reaches no account.
        #expect(ledger.accounts.map(\.id) == [codex])
        for account in ledger.accounts {
            for w in WindowKind.allCases {
                #expect(ledger.latest(account.id, w)?.reading.fileKey != "codex-gone@example.com.json")
            }
        }
    }

    @Test func unclassifiedResolvesThroughCredential() {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let codexFile = "codex-user-1@example.com-plus.json"
        let codex = AccountID(provider: .codex, identity: "chatgpt-acct-7f3e")
        let u = UnclassifiedReading(provider: .codex, fileKey: codexFile, lengthSeconds: nil, usedPercent: 4,
                                    resetsAt: nil, observedAt: t("11:00"))
        let stray = UnclassifiedReading(provider: .codex, fileKey: "codex-other.json", lengthSeconds: 60,
                                        usedPercent: 9, resetsAt: nil, observedAt: t("11:00"))
        ledger.apply(cliproxy(t("11:00"), [cred(.codex, "chatgpt-acct-7f3e", file: codexFile)],
                              unclassified: [u, stray]))
        #expect(ledger.unclassified(codex) == [u])
    }
}

@Suite("T4 ledger: merge and aliases")
struct T4MergeTests {
    let store = T4FakeHistoryStore()

    @Test func credentialMergeKeepsRoutesPerFile() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let fileB = "claude-bbbb0002-b@example.com.json"
        ledger.apply(cliproxy(t("11:00"), [
            cred("aaaa0001", file: fileA, email: "a@example.com", counter: 10,
                 routing: AccountRouting(priority: 0, weight: 1)),
            cred("aaaa0001", file: fileA2, unavailable: [.upstreamUnavailable], counter: 3,
                 routing: AccountRouting(priority: 0, weight: 1)),
            cred("bbbb0002", file: fileB, email: "b@example.com", counter: 5,
                 routing: AccountRouting(priority: 0, weight: 1)),
        ], routing: RoutingConfig(strategy: .roundRobin, sessionAffinity: false, forcedAccount: nil)))

        let accounts = ledger.accounts
        #expect(accounts.count == 2)
        let a = try #require(accounts.first { $0.id == idA })
        #expect(a.enabled)
        #expect(a.unavailable.isEmpty)   // one enabled credential is available
        #expect(a.email == "a@example.com")
        // Routes are ordered by fileKey.
        #expect(a.credentials == [
            CredentialRoute(fileKey: fileA, priority: 0, weight: 1, enabled: true, unavailable: []),
            CredentialRoute(fileKey: fileA2, priority: 0, weight: 1, enabled: true,
                            unavailable: [.upstreamUnavailable]),
        ].sorted { $0.fileKey < $1.fileKey })
        let b = try #require(accounts.first { $0.id.identity == "bbbb0002" })
        #expect(b.enabled && b.unavailable.isEmpty)
        #expect(b.credentials == [CredentialRoute(fileKey: fileB, priority: 0, weight: 1, enabled: true,
                                                  unavailable: [])])
        #expect(b.email == "b@example.com")
        // T11b's 1/2 case: round-robin over A's available credentials and B's.
        let available = accounts.flatMap(\.credentials).filter { $0.enabled && $0.unavailable.isEmpty }
        #expect(available.filter { $0.fileKey.contains("aaaa0001") }.count == 1)
        #expect(available.count == 2)
    }

    @Test func enabledIfAnyFileAvailableIfAnyEnabledFile() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(cliproxy(t("11:00"), [
            cred("aaaa0001", file: fileA, enabled: false),
            cred("aaaa0001", file: fileA2, unavailable: [.upstreamUnavailable]),
        ]))
        let a = try #require(ledger.accounts.first)
        #expect(a.enabled)
        // The disabled file's availability doesn't count; the enabled one is unavailable.
        #expect(a.unavailable == [.upstreamUnavailable])

        ledger.apply(cliproxy(t("11:01"), [
            cred("aaaa0001", file: fileA, enabled: false),
            cred("aaaa0001", file: fileA2, enabled: false),
        ]))
        #expect(ledger.accounts.first?.enabled == false)
    }

    /// A's two credentials are both blocked at 12:30; A's 5-hour reading is 40 used
    /// (60 left), reset 15:00. A takes traffic again when its first credential comes
    /// back, at 13:00, before the 15:00 reset, so the refill is A's 60 left at 13:00
    /// (one account, so +60 to the pool). A union of the reasons would end the block at
    /// 14:00 in the first case and never in the second.
    static let blockedCredentialCases: [(second: Unavailability, label: String)] = [
        (.coolingDown(until: t("14:00")), "cooling until 14:00"),
        (.outOfRotation, "out of rotation"),
    ]

    @Test(arguments: blockedCredentialCases)
    func accountComesBackWithItsFirstCredential(second: Unavailability, label: String) throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let now = t("12:30")
        ledger.apply(cliproxy(now, [
            cred("aaaa0001", file: fileA, unavailable: [.coolingDown(until: t("13:00"))]),
            cred("aaaa0001", file: fileA2, unavailable: [second]),
        ], readings: [reading(fileA, .fiveHour, used: 40, resets: t("15:00"), at: t("12:25"))],
           routing: RoutingConfig(strategy: .roundRobin, sessionAffinity: false, forcedAccount: nil)))

        let a = try #require(ledger.accounts.first)
        #expect(a.unavailable == [.coolingDown(until: t("13:00"))], "\(label)")

        let model = PoolEngine.dashboard(ledger: ledger, settings: PoolSettings(),
                                         sources: [.cliproxy: .ok(at: now)], now: now)
        let refill = try #require(model.row(.claude)?.fiveHour?.nextRefill, "\(label)")
        #expect(refill.at == t("13:00"), "\(label)")
        #expect(abs(refill.poolGain - 60) < 1e-9, "\(label)")
    }

    @Test func e14TwoAccountsThenOneWithAlias() throws {
        let legacy = "claude-x@example.com.json"
        let hashed = AccountID(provider: .claude, identity: "1a2b3c4d")
        let snapshot = cliproxy(t("11:00"), [
            cred("1a2b3c4d", file: "claude-1a2b3c4d-x@example.com.json"),
            cred("1a2b3c4d", file: "claude-1a2b3c4d-x@example.com-2.json"),
            cred("x@example.com", file: legacy),
        ], readings: [reading(legacy, .weekly, used: 35, resets: nil, at: t("10:59"))])
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(snapshot)
        #expect(ledger.accounts.map(\.id.identity) == ["1a2b3c4d", "x@example.com"])
        #expect(ledger.accounts.map(\.alias) == ["claude-1", "claude-2"])
        #expect(ledger.latest(hashed, .weekly) == nil)

        // Same alias passed to a running ledger merges without a restore.
        ledger.updateSettings(PoolSettings(identityAliases: [legacy: "1a2b3c4d"]))
        let accounts = ledger.accounts
        #expect(accounts.map(\.id) == [hashed])
        #expect(accounts.first?.alias == "claude-1")
        #expect(accounts.first?.colorIndex == 0)
        #expect(accounts.first?.credentials.count == 3)
        let weekly = try #require(ledger.latest(hashed, .weekly))
        #expect(weekly.account == hashed)
        #expect(weekly.reading.fileKey == legacy)
        #expect(weekly.reading.usedPercent == 35)
    }

    @Test func e14AliasOnRestoreReattachesStoredReadings() throws {
        let legacy = "claude-x@example.com.json"
        let hashed = AccountID(provider: .claude, identity: "1a2b3c4d")
        // A previous run, with no alias, stored the legacy file's reading.
        let first = Ledger(store: store, settings: PoolSettings())
        try t4PersistAndApply(cliproxy(t("11:00"), [
            cred("1a2b3c4d", file: "claude-1a2b3c4d-x@example.com.json"),
            cred("x@example.com", file: legacy),
        ], readings: [reading(legacy, .weekly, used: 35, resets: nil, at: t("10:59")),
                      reading("claude-1a2b3c4d-x@example.com.json", .fiveHour, used: 12, resets: nil,
                              at: t("10:58"))]),
            store: store, ledger: first)
        #expect(first.accounts.count == 2)

        // The alias is added, then the app relaunches.
        let restored = Ledger(store: store, settings: PoolSettings(identityAliases: [legacy: "1a2b3c4d"]))
        try restored.restore()
        #expect(restored.accounts.map(\.id) == [hashed])
        #expect(restored.accounts.first?.alias == "claude-1")
        #expect(restored.latest(hashed, .weekly)?.reading.fileKey == legacy)
        #expect(restored.latest(hashed, .weekly)?.reading.usedPercent == 35)
        #expect(restored.latest(hashed, .fiveHour)?.reading.usedPercent == 12)
    }

    @Test func aliasAndColorComeFromTheStore() throws {
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(ocgo(t("11:00"), [goAccount("team-a", polledAt: t("11:00")),
                                       goAccount("team-b", polledAt: t("11:00"))]))
        ledger.apply(cliproxy(t("11:00"), [cred("aaaa0001", file: fileA)]))
        #expect(ledger.accounts.map(\.alias) == ["claude-1", "go-1", "go-2"])
        #expect(ledger.accounts.map(\.colorIndex) == [0, 0, 1])
        // Each account is assigned once, not on every write or read.
        let calls = store.aliasCalls
        ledger.apply(cliproxy(t("11:01"), [cred("aaaa0001", file: fileA)]))
        _ = ledger.accounts
        #expect(store.aliasCalls == calls)
    }

    @Test func aliasFailureShowsPlaceholderWithoutIdentityAndRetries() {
        let ledger = Ledger(store: store, settings: PoolSettings())
        let legacy = cred("x@example.com", file: "claude-x@example.com.json")
        store.failAliases = true
        ledger.apply(cliproxy(t("11:00"), [legacy]))
        let placeholder = ledger.accounts.first?.alias
        #expect(placeholder == "claude-?")
        #expect(placeholder?.contains("@") == false)

        // Not cached: the next write asks the store again.
        store.failAliases = false
        ledger.apply(cliproxy(t("11:01"), [legacy]))
        #expect(ledger.accounts.first?.alias == "claude-1")
    }
}

@Suite("T4 ledger: restore")
struct T4RestoreTests {
    let store = T4FakeHistoryStore()
    let idCodex = AccountID(provider: .codex, identity: "chatgpt-acct-1")
    let idB = AccountID(provider: .claude, identity: "bbbb0002")
    let fileB = "claude-bbbb0002-b@example.com.json"
    let fileCodex = "codex-user-1@example.com-plus.json"

    /// E7 snapshot 1 with a cliproxy listing, the ocgo snapshot, then E7 snapshot 2.
    private func populate(_ ledger: Ledger) throws {
        let routing = RoutingConfig(strategy: .fillFirst, sessionAffinity: true, forcedAccount: nil)
        let unclassified = UnclassifiedReading(provider: .codex, fileKey: fileCodex, lengthSeconds: nil,
                                               usedPercent: 4, resetsAt: nil, observedAt: t("11:50"))
        try t4PersistAndApply(cliproxy(t("11:50"), [
            cred("aaaa0001", file: fileA, email: "a@example.com", counter: 1500,
                 routing: AccountRouting(priority: 1, weight: 1)),
            cred("bbbb0002", file: fileB, counter: 300),
            cred(.codex, "chatgpt-acct-1", file: fileCodex, counter: 800),
        ], readings: [
            reading(fileA, .fiveHour, used: 30, resets: t("14:00"), at: t("11:50")),
            reading(fileA, .weekly, used: 10, resets: t("12:00"), at: t("11:50")),
            reading(fileB, .weekly, used: 50, resets: t("12:00"), at: t("11:50")),
            reading(.codex, fileCodex, .weekly, used: 20, resets: t("12:00"), at: t("11:50")),
        ], unclassified: [unclassified], routing: routing), store: store, ledger: ledger)

        try t4PersistAndApply(ocgo(t("11:52"), [
            goAccount("team-a", polledAt: t("11:51"), unavailable: [.notForcedAccount]),
            goAccount("team-b", polledAt: t("11:51"), unavailable: []),
            goAccount("team-c", polledAt: nil, unavailable: [.notForcedAccount]),   // never polled
        ], readings: [
            reading(.go, "team-a", .fiveHour, used: 52, resets: t("12:00"), at: t("11:51"), source: .ocgo),
            reading(.go, "team-b", .fiveHour, used: 40, resets: t("15:00"), at: t("11:51"), source: .ocgo),
        ], forced: "team-b"), store: store, ledger: ledger)

        // E7 snapshot 2: weekly only for A; B used; codex idle.
        try t4PersistAndApply(cliproxy(t("12:05"), [
            cred("aaaa0001", file: fileA, email: "a@example.com", counter: 1500,
                 routing: AccountRouting(priority: 1, weight: 1)),
            cred("bbbb0002", file: fileB, counter: 304),
            cred(.codex, "chatgpt-acct-1", file: fileCodex, counter: 800),
        ], readings: [
            reading(fileA, .weekly, used: 12, resets: date("2026-11-29T12:00:00Z"), at: t("12:05")),
        ], unclassified: [unclassified], routing: routing), store: store, ledger: ledger)
    }

    private struct Answers: Equatable {
        var accounts: [MergedAccount]
        var routing: [SourceKind: RoutingConfig]
        var latest: [String: WindowReading]
        var unclassified: [String: [UnclassifiedReading]]
        var proofs: [String: Bool]
    }

    private func answers(_ ledger: Ledger) -> Answers {
        let ids = ledger.accounts.map(\.id) + [AccountID(provider: .claude, identity: "nobody")]
        var latest: [String: WindowReading] = [:]
        var unclassified: [String: [UnclassifiedReading]] = [:]
        var proofs: [String: Bool] = [:]
        for id in ids {
            let key = "\(id.provider)/\(id.identity)"
            unclassified[key] = ledger.unclassified(id)
            for w in WindowKind.allCases {
                latest["\(key)/\(w)"] = ledger.latest(id, w)
                for reset in [t("11:55"), t("12:00"), t("12:03"), t("12:10")] {
                    proofs["\(key)/\(w)/\(reset.timeIntervalSince1970)"] =
                        ledger.resetProven(id, w, resetAt: reset)
                }
            }
        }
        return Answers(accounts: ledger.accounts, routing: ledger.routing, latest: latest,
                       unclassified: unclassified, proofs: proofs)
    }

    @Test func restoreGivesTheSameAnswers() throws {
        let live = Ledger(store: store, settings: PoolSettings())
        try populate(live)
        let restored = Ledger(store: store, settings: PoolSettings())
        try restored.restore()

        let before = answers(live)
        let after = answers(restored)
        #expect(after.accounts == before.accounts)
        #expect(after.routing == before.routing)
        #expect(after.latest == before.latest)
        #expect(after.unclassified == before.unclassified)
        #expect(after.proofs == before.proofs)
    }

    @Test func restoredStateMatchesThePlan() throws {
        let live = Ledger(store: store, settings: PoolSettings())
        try populate(live)
        let ledger = Ledger(store: store, settings: PoolSettings())
        try ledger.restore()

        // E7 after restore: 5-hour 30% keeps snapshot 1's time; weekly is 12%.
        let fiveHour = try #require(ledger.latest(idA, .fiveHour))
        #expect(fiveHour.reading.usedPercent == 30)
        #expect(fiveHour.reading.observedAt == t("11:50"))
        #expect(ledger.latest(idA, .weekly)?.reading.usedPercent == 12)

        // Accounts: three cliproxy, three Go, including the never-polled one.
        #expect(Set(ledger.accounts.map(\.id.identity))
                == ["aaaa0001", "bbbb0002", "chatgpt-acct-1", "team-a", "team-b", "team-c"])
        let teamC = AccountID(provider: .go, identity: "team-c")
        #expect(ledger.accounts.contains { $0.id == teamC })
        for w in WindowKind.allCases { #expect(ledger.latest(teamC, w) == nil) }
        #expect(ledger.accounts.first { $0.id.identity == "team-a" }?.unavailable == [.notForcedAccount])

        // Routing for both sources, with the forced account.
        #expect(ledger.routing[.ocgo]?.forcedAccount == AccountID(provider: .go, identity: "team-b"))
        #expect(ledger.routing[.cliproxy] == RoutingConfig(strategy: .fillFirst, sessionAffinity: true,
                                                           forcedAccount: nil))

        // Proofs: codex idle across 12:00 (800 -> 800); B used (300 -> 304); A's weekly
        // has a fresh reading; team-a has no rolling reading at or after 12:00.
        #expect(ledger.resetProven(idCodex, .weekly, resetAt: t("12:00")))
        #expect(!ledger.resetProven(idB, .weekly, resetAt: t("12:00")))
        #expect(ledger.resetProven(idA, .weekly, resetAt: t("12:00")))
        #expect(!ledger.resetProven(AccountID(provider: .go, identity: "team-a"), .fiveHour,
                                    resetAt: t("12:00")))

        #expect(ledger.unclassified(idCodex).map(\.usedPercent) == [4])
    }

    @Test func restoredLedgerContinuesCounterRuns() throws {
        let live = Ledger(store: store, settings: PoolSettings())
        try t4PersistAndApply(cliproxy(t("11:50"), [cred("aaaa0001", file: fileA, counter: 1500)]),
                              store: store, ledger: live)
        let restored = Ledger(store: store, settings: PoolSettings())
        try restored.restore()
        restored.apply(cliproxy(t("12:05"), [cred("aaaa0001", file: fileA, counter: 1500)]))
        #expect(restored.resetProven(idA, .fiveHour, resetAt: t("12:00")))
    }
}

@Suite("T4 ledger: concurrency")
struct T4ConcurrencyTests {
    @Test func readsDuringWritesAreSafe() async {
        let ledger = Ledger(store: T4FakeHistoryStore(), settings: PoolSettings())
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<200 {
                    let at = t("11:00").addingTimeInterval(Double(i) * 60)
                    ledger.apply(cliproxy(at, [cred("aaaa0001", file: fileA, counter: i)],
                                          readings: [reading(fileA, .weekly, used: Double(i % 100),
                                                             resets: nil, at: at)]))
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<200 {
                        _ = ledger.accounts
                        _ = ledger.latest(idA, .weekly)
                        _ = ledger.resetProven(idA, .weekly, resetAt: t("12:00"))
                    }
                }
            }
        }
        #expect(ledger.latest(idA, .weekly)?.reading.usedPercent == 99)
    }
}
