import Foundation
import Testing
@testable import UsageCore

// T11b. Every expected time is worked out by hand from plan.md's simulation rules
// (see LockoutSimulation's doc comment), never from running the simulation. Times are
// UTC on 2026-11-22; now is 12:00, so the horizon ends at 17:00.

private let now = t11("12:00")

private func span(_ from: String, _ to: String) -> DateInterval {
    DateInterval(start: t11(from), end: t11(to))
}

@Suite("T11b 5-hour simulation: one three-account case per strategy")
struct T11StrategyTests {
    /// Three subscriptions, demand 120 account-% per hour (2 per minute):
    ///   A: 70 left, 5-hour reset 15:00
    ///   B: 40 left, reset 15:30
    ///   C: 40 left, reset 12:30 (resets early, so what it hasn't used then is lost)
    /// Total before any reset: 150. Every pool-level lockout starts when the quota
    /// consumed (2 per minute) reaches 150 + what C's 12:30 reset adds (100 minus what C
    /// still had), so each strategy differs by how much of C it used before 12:30.
    func ledger(_ provider: Provider, _ routing: RoutingConfig,
                weights: [Int] = [1, 1, 1]) -> T3FakeLedgerView {
        var l = T3FakeLedgerView()
        let names = provider == .go ? ["team-a", "team-b", "team-c"] : ["a", "b", "c"]
        let levels: [(used: Double, reset: String)] = [(30, "15:00"), (60, "15:30"), (60, "12:30")]
        for (i, name) in names.enumerated() {
            let id = l.t11Add(provider, name, routes: [t11Route(name, weight: weights[i])])
            l.set(id, .fiveHour, used: levels[i].used, resets: t11(levels[i].reset),
                  at: t11("11:59"))
        }
        l.routing[provider == .go ? .ocgo : .cliproxy] = routing
        return l
    }

    func lockouts(_ l: T3FakeLedgerView, _ provider: Provider) -> [DateInterval]? {
        LockoutSimulation.lockouts(provider, ledger: l, demandPerHour: 120, now: now)
    }

    @Test func roundRobin() {
        // Equal shares per usable credential.
        // 12:00-12:30  A, B, C 2/3 each: A 70->50, B 40->20, C 40->20.
        // 12:30        C resets with 20 unused -> 100; used at once, window ends 17:30.
        // 12:30-13:00  2/3 each: B 20->0 at 13:00; A 50->30; C 100->80.
        // 13:00-13:30  A, C 1 each: A 30->0 at 13:30; C 80->50.
        // 13:30-13:55  C alone 2/min: 50->0 at 13:55.   (check: 150 + 80 = 230 = 115 min)
        // 13:55        lockout until A's reset at 15:00.
        // 15:00        A fresh (window ends 20:00), alone: 100->40 by 15:30.
        // 15:30        B resets, fresh (window ends 20:30). A, B 1 each: A 40->0 at 16:10,
        //              B 100->60; then B alone 2/min: 60->0 at 16:40.
        // 16:40        lockout until C's window resets at 17:30.
        let l = ledger(.claude, t11Routing(.roundRobin))
        #expect(lockouts(l, .claude) == [span("13:55", "15:00"), span("16:40", "17:30")])
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("13:55"), to: t11("15:00")))
    }

    @Test func weightedRoundRobin() {
        // Weights A 1, B 1, C 2: shares 0.5, 0.5, 1 per minute.
        // 12:00-12:30  A 70->55, B 40->25, C 40->10.
        // 12:30        C resets with 10 unused -> 100, window ends 17:30.
        // 12:30-13:20  B 25->0 at 13:20 (0.5/min); A 55->30; C 100->50.
        // 13:20-14:00  A (w1) and C (w2) hold 30 + 50 = 80 at 2/min: empty at 14:00
        //              (C runs out at 13:57:30 and A takes the rest).
        //              (check: 150 + 90 = 240 = 120 min)
        // 14:00        lockout until A's reset at 15:00.
        // 15:00        A fresh, alone: 100->40 by 15:30. 15:30 B fresh; A, B 1 each:
        //              A 40->0 at 16:10, B 100->60, then alone: 60->0 at 16:40.
        // 16:40        lockout until C's reset at 17:30.
        let l = ledger(.claude, t11Routing(.weightedRoundRobin), weights: [1, 1, 2])
        #expect(lockouts(l, .claude) == [span("14:00", "15:00"), span("16:40", "17:30")])
    }

    @Test func fillFirst() {
        // Everything to the first usable credential by fileKey: a, b, c.
        // 12:00-12:35  A 70->0.
        // 12:30        C resets unused (40 lost) -> 100, idle: no window yet.
        // 12:35-12:55  B 40->0.
        // 12:55-13:45  C: first use starts its window (ends 17:55); 100->0 at 13:45.
        //              (check: 150 + 60 = 210 = 105 min)
        // 13:45        lockout until A's reset at 15:00.
        // 15:00-15:50  A fresh (window ends 20:00), first in order: 100->0. B resets at
        //              15:30 but waits.
        // 15:50-16:40  B: window starts (ends 20:50); 100->0.
        // 16:40        lockout until C's window resets at 17:55 (not 17:30: it started
        //              on first use at 12:55).
        let l = ledger(.claude, t11Routing(.fillFirst))
        #expect(lockouts(l, .claude) == [span("13:45", "15:00"), span("16:40", "17:55")])
    }

    @Test func mostHeadroom() {
        // ocgo: demand to the most headroom, so the fullest accounts level down together.
        // 12:00-12:15  A alone: 70->40.
        // 12:15-12:30  A, B, C level together, 2/3 each: 40->30.
        // 12:30        C resets with 30 unused -> 100; most headroom, used at once
        //              (window ends 17:30).
        // 12:30-13:05  C alone: 100->30.
        // 13:05-13:50  all three at 30, 2/3 each: empty at 13:50.
        //              (check: 150 + 70 = 220 = 110 min)
        // 13:50        lockout until A's reset at 15:00.
        // 15:00-15:30  A fresh (window ends 20:00), alone: 100->40.
        // 15:30        B resets, fresh, most headroom: 100->40 by 16:00 (window ends 20:30).
        // 16:00-16:40  A, B at 40, 1 each: empty at 16:40.
        // 16:40        lockout until C's reset at 17:30.
        let l = ledger(.go, t11Routing(.mostHeadroom))
        #expect(lockouts(l, .go) == [span("13:50", "15:00"), span("16:40", "17:30")])
    }

    @Test func mostHeadroomCountsTheWeeklyWindow() {
        // Go: A 5-hour 80 left (reset 15:00) but weekly 50 left, so A's headroom is 50.
        // B 5-hour 60 left, reset 12:10, no weekly reading. Demand 2/min.
        // 12:00-12:05  B (60) above A (50): B 60->50.
        // 12:05-12:10  both at headroom 50; A's 5-hour is above its cap, so A takes
        //              demand without losing headroom: A 80->70.
        // 12:10        B resets with 50 unused -> 100 (window ends 17:10).
        // 12:10-12:35  B alone: 100->50.
        // 12:35-12:45  A again drains its surplus: 70->50.
        // 12:45-13:35  A, B at 50, 1 each: empty at 13:35.  (140 + 50 = 190 = 95 min)
        // 13:35        lockout until A's reset at 15:00.
        // Using the 5-hour level alone (A first, B loses 60 at 12:10) would give 13:30.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.go, "team-a")
        let b = l.t11Add(.go, "team-b")
        l.set(a, .fiveHour, used: 20, resets: t11("15:00"), at: t11("11:59"))
        l.set(a, .weekly, used: 50, resets: t11("12:00", plusDays: 3), at: t11("11:59"))
        l.set(b, .fiveHour, used: 40, resets: t11("12:10"), at: t11("11:59"))
        l.routing[.ocgo] = t11Routing(.mostHeadroom)
        #expect(LockoutSimulation.forecast(.go, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("13:35"), to: t11("15:00")))
    }
}

@Suite("T11b 5-hour simulation: routes, blocks and withheld")
struct T11RoutingTests {
    let db = T5TempDatabase()
    let fileA = "claude-aaaa0001-a@example.com.json"
    let fileA2 = "claude-aaaa0001-a2@example.com.json"
    let fileB = "claude-bbbb0002-b@example.com.json"

    func snapshot(_ at: Date, a2Unavailable: Bool) -> SourceSnapshot {
        func cred(_ identity: String, _ file: String, unavailable: [Unavailability] = []) -> AccountSnapshot {
            AccountSnapshot(id: AccountID(provider: .claude, identity: identity), fileKey: file,
                            email: nil, enabled: true, unavailable: unavailable, requestCounter: 0,
                            routing: AccountRouting(priority: 0, weight: 1), polledAt: nil,
                            pollError: nil)
        }
        return SourceSnapshot(
            source: .cliproxy, takenAt: at,
            accounts: [cred("aaaa0001", fileA),
                       cred("aaaa0001", fileA2, unavailable: a2Unavailable ? [.upstreamUnavailable] : []),
                       cred("bbbb0002", fileB)],
            readings: [t11Reading(fileA, used: 40, resets: t11("15:00"), at: at),
                       t11Reading(fileB, used: 40, resets: t11("15:30"), at: at)],
            unclassified: [], routing: t11Routing(.roundRobin))
    }

    @Test func twoCredentialsTakeTwoSharesUnderRoundRobin() throws {
        // Real ledger merge (T4): A has two equal-weight credentials, B one. Round-robin
        // per credential: A 2/3, B 1/3; with one of A's credentials unavailable, 1/2 each.
        let store = try SQLiteHistoryStore(path: db.path, retention: nil)
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(snapshot(t11("11:59"), a2Unavailable: false))
        let a = AccountID(provider: .claude, identity: "aaaa0001")
        let b = AccountID(provider: .claude, identity: "bbbb0002")

        var shares = LockoutSimulation.shares(.claude, ledger: ledger, now: now)
        #expect(abs(shares[a, default: 0] - 2.0 / 3) < 1e-6)
        #expect(abs(shares[b, default: 0] - 1.0 / 3) < 1e-6)

        ledger.apply(snapshot(t11("11:59"), a2Unavailable: true))
        shares = LockoutSimulation.shares(.claude, ledger: ledger, now: now)
        #expect(abs(shares[a, default: 0] - 0.5) < 1e-6)
        #expect(abs(shares[b, default: 0] - 0.5) < 1e-6)
    }

    @Test func weightedSplitsByCredentialWeight() {
        // A: weights 2 and 1, B: 1 -> A 3/4, B 1/4.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a", routes: [t11Route("a1", weight: 2), t11Route("a2", weight: 1)])
        let b = l.t11Add(.claude, "b")
        l.set(a, .fiveHour, used: 0, resets: t11("15:00"), at: now)
        l.set(b, .fiveHour, used: 0, resets: t11("15:00"), at: now)
        l.routing[.cliproxy] = t11Routing(.weightedRoundRobin)
        let shares = LockoutSimulation.shares(.claude, ledger: l, now: now)
        #expect(abs(shares[a, default: 0] - 0.75) < 1e-6)
        #expect(abs(shares[b, default: 0] - 0.25) < 1e-6)
    }

    @Test func higherPriorityTierTakesEverythingFirst() {
        // A priority 1 (40 left, reset 14:00); B, C priority 0 (40 left, reset 16:00).
        // Demand 2/min: A alone 12:00-12:20, then B, C 1 each until 13:00. Lockout
        // 13:00 until A's reset at 14:00.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a", routes: [t11Route("a", priority: 1)])
        let b = l.t11Add(.claude, "b")
        let c = l.t11Add(.claude, "c")
        l.set(a, .fiveHour, used: 60, resets: t11("14:00"), at: now)
        l.set(b, .fiveHour, used: 60, resets: t11("16:00"), at: now)
        l.set(c, .fiveHour, used: 60, resets: t11("16:00"), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        let shares = LockoutSimulation.shares(.claude, ledger: l, now: now)
        #expect(Set(shares.keys) == [a])
        #expect(abs(shares[a, default: 0] - 1) < 1e-6)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("13:00"), to: t11("14:00")))
    }

    @Test func forcedAccountTakesAllDemand() {
        // ocgo forced_account team-b (40 left, reset 13:30); team-a is full but ocgo
        // doesn't fail over. Demand 2/min: B empty at 12:20, lockout until 13:30. The
        // fake ledger leaves out `notForcedAccount`, so the routing alone decides.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.go, "team-a")
        let b = l.t11Add(.go, "team-b")
        l.set(a, .fiveHour, used: 0, at: now)
        l.set(b, .fiveHour, used: 60, resets: t11("13:30"), at: now)
        l.routing[.ocgo] = t11Routing(.mostHeadroom, forced: b)
        #expect(LockoutSimulation.forecast(.go, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("12:20"), to: t11("13:30")))
    }

    @Test func weeklyBlockLiftsAtTheWeeklyReset() {
        // A: 5-hour full and idle, weekly 0 left until 13:00. B: 40 left, reset 16:00.
        // Demand 2/min: B empty at 12:20; A usable again at 13:00.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        let b = l.t11Add(.claude, "b")
        l.set(a, .fiveHour, used: 0, at: now)
        l.set(a, .weekly, used: 100, resets: t11("13:00"), at: now)
        l.set(b, .fiveHour, used: 60, resets: t11("16:00"), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("12:20"), to: t11("13:00")))
    }

    @Test func cooldownEndsAtItsTime() {
        // A cooling down until 12:30 with 100 left; B 20 left, reset 15:00. Demand 2/min:
        // B empty at 12:10, lockout until A's cooldown ends at 12:30.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.go, "team-a", unavailable: [.coolingDown(until: t11("12:30"))])
        let b = l.t11Add(.go, "team-b")
        l.set(a, .fiveHour, used: 0, at: now)
        l.set(b, .fiveHour, used: 80, resets: t11("15:00"), at: now)
        l.routing[.ocgo] = t11Routing(.mostHeadroom)
        #expect(LockoutSimulation.forecast(.go, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("12:10"), to: t11("12:30")))
    }

    @Test func idleAccountWindowStartsOnFirstUse() {
        // One account, full and idle. Demand 30/h (0.5/min): it starts a window at
        // 12:00 that ends at 17:00, and 100 lasts 200 min, to 15:20. Lockout 15:20 to
        // 17:00.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        l.set(a, .fiveHour, used: 0, at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 30, now: now)
                == .lockout(from: t11("15:20"), to: t11("17:00")))
    }

    @Test func provenPastResetCountsAsFullAndUnprovenIsUnknown() {
        // A's window ended at 11:30. With proof it is full and idle: as above, 15:20 to
        // 17:00. Without proof it is unknown: insufficient data.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        l.set(a, .fiveHour, used: 90, resets: t11("11:30"), at: t11("11:00"))
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 30, now: now)
                == .insufficientData)
        l.prove(a, .fiveHour, resetAt: t11("11:30"), true)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 30, now: now)
                == .lockout(from: t11("15:20"), to: t11("17:00")))
    }

    @Test func unknownAccountThatCanNeverTakeTrafficDoesNotMatter() {
        // B is unknown but upstream-unavailable for the whole run; A alone: 20 left at
        // 2/min -> 12:10, reset 13:00.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        l.t11Add(.claude, "b", unavailable: [.upstreamUnavailable])
        l.set(a, .fiveHour, used: 80, resets: t11("13:00"), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("12:10"), to: t11("13:00")))
    }

    @Test func safeWhenThePoolOutlastsTheHorizon() {
        // Two full idle accounts at 20/h: 200 lasts 10 h.
        var l = T3FakeLedgerView()
        for name in ["a", "b"] {
            let id = l.t11Add(.claude, name)
            l.set(id, .fiveHour, used: 0, at: now)
        }
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 20, now: now) == .safe)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 0, now: now) == .safe)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: nil, now: now)
                == .insufficientData)
    }

    // MARK: Review round 1

    @Test func zeroDemandWhileEmptyNowReportsTheCurrentLockout() {
        // Item A. Every account 100% used, 5-hour reset 14:00. Nothing burns (demand 0),
        // but nothing is usable at 12:00 either: locked out 12:00 until 14:00.
        var l = T3FakeLedgerView()
        for name in ["a", "b"] {
            let id = l.t11Add(.claude, name)
            l.set(id, .fiveHour, used: 100, resets: t11("14:00"), at: t11("11:59"))
        }
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 0, now: now)
                == .lockout(from: t11("12:00"), to: t11("14:00")))
    }

    @Test func lockoutPastTheHorizonEndsAtTheWeeklyReset() {
        // Item B. The only account is full on 5 hours but weekly-blocked until tomorrow
        // 12:00. Locked out from 12:00; nothing drains while locked out, so it ends
        // when the weekly window resets: 2026-11-23 12:00 (not a made-up 22:00).
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        l.set(a, .fiveHour, used: 0, at: now)
        l.set(a, .weekly, used: 100, resets: t11("12:00", plusDays: 1), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 60, now: now)
                == .lockout(from: t11("12:00"), to: t11("12:00", plusDays: 1)))
    }

    @Test func lockoutPastTheHorizonEndsWhenExhaustionEnds() {
        // Item B. ocgo account exhausted until now + 12 h = 2026-11-23 00:00, 5-hour full.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.go, "team-a", unavailable: [.exhausted(until: t11("00:00", plusDays: 1))])
        l.set(a, .fiveHour, used: 0, at: now)
        l.routing[.ocgo] = t11Routing(.mostHeadroom)
        #expect(LockoutSimulation.forecast(.go, ledger: l, demandPerHour: 60, now: now)
                == .lockout(from: t11("12:00"), to: t11("00:00", plusDays: 1)))
    }

    @Test func lockoutWithNoKnownRecoveryIsInsufficientData() {
        // Item B. Every account upstream-unavailable (no end date): locked out with no
        // known end.
        var l = T3FakeLedgerView()
        for name in ["a", "b"] {
            let id = l.t11Add(.claude, name, unavailable: [.upstreamUnavailable])
            l.set(id, .fiveHour, used: 0, at: now)
        }
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 60, now: now)
                == .insufficientData)
        #expect(LockoutSimulation.lockouts(.claude, ledger: l, demandPerHour: 60, now: now) == nil)
    }

    @Test func accountThatEmptiesWithNoResetIsInsufficientData() {
        // Item B. One account, 50 left, no 5-hour reset known. At 60/h (1/min) it empties
        // at 12:50 and nothing says when it refills.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        l.set(a, .fiveHour, used: 50, at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 60, now: now)
                == .insufficientData)
    }

    @Test func unknownAccountBlockedPastTheHorizonIsLeftOut() {
        // Item C. A and B: 40 left each, 5-hour reset 15:00. C: weekly 0 left for 3 days
        // and a 5-hour window that ended at 11:30 without proof (unknown). C can't take
        // traffic before 17:00, so the forecast comes from A and B: 2/min round-robin,
        // 1 each, 40 lasts 40 min -> lockout 12:40 until the 15:00 resets.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        let b = l.t11Add(.claude, "b")
        let c = l.t11Add(.claude, "c")
        l.set(a, .fiveHour, used: 60, resets: t11("15:00"), at: now)
        l.set(b, .fiveHour, used: 60, resets: t11("15:00"), at: now)
        l.set(c, .fiveHour, used: 90, resets: t11("11:30"), at: t11("11:00"))
        l.set(c, .weekly, used: 100, resets: t11("12:00", plusDays: 3), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .lockout(from: t11("12:40"), to: t11("15:00")))

        // Same with C cooling down until 18:00 (after the horizon) instead of weekly.
        var m = T3FakeLedgerView()
        let ma = m.t11Add(.go, "team-a")
        let mb = m.t11Add(.go, "team-b")
        let mc = m.t11Add(.go, "team-c", unavailable: [.coolingDown(until: t11("18:00"))])
        m.set(ma, .fiveHour, used: 60, resets: t11("15:00"), at: now)
        m.set(mb, .fiveHour, used: 60, resets: t11("15:00"), at: now)
        m.set(mc, .fiveHour, used: 90, resets: t11("11:30"), at: t11("11:00"))
        m.routing[.ocgo] = t11Routing(.mostHeadroom)
        #expect(LockoutSimulation.forecast(.go, ledger: m, demandPerHour: 120, now: now)
                == .lockout(from: t11("12:40"), to: t11("15:00")))
    }

    @Test func zeroDemandWithAKnownUsableAccountIsSafeDespiteAnUnknownOne() {
        // Item F. A: 100 left (used 0), usable now. B: 5-hour window ended 11:30 without
        // proof (unknown) and no other block, so it could take traffic. Zero demand
        // drains nothing and A is usable at 12:00 -> safe, whatever B holds.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        let b = l.t11Add(.claude, "b")
        l.set(a, .fiveHour, used: 0, at: now)
        l.set(b, .fiveHour, used: 90, resets: t11("11:30"), at: t11("11:00"))
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 0, now: now) == .safe)
        #expect(LockoutSimulation.lockouts(.claude, ledger: l, demandPerHour: 0, now: now) == [])
        // With demand, B's share is unknown: no answer.
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 60, now: now)
                == .insufficientData)
        // A empty now (used 100, reset 13:00): no known account usable at 12:00, and B
        // might be, so even zero demand has no answer.
        l.set(a, .fiveHour, used: 100, resets: t11("13:00"), at: now)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 0, now: now)
                == .insufficientData)
    }

    @Test func unknownAccountUnblockingBeforeTheRecoveryLeavesTheEndUnknown() {
        // Item G, Neon's case. a: 5-hour full but weekly 0 until 2026-11-25 12:00 (3
        // days). b: 5-hour unknown (ended 11:30, no proof), weekly 0 until 2026-11-23
        // 12:00 (1 day), past 17:00, so b is left out. Locked out from 12:00; a recovers
        // 2026-11-25 12:00, but b unblocks 2026-11-23 12:00, before that, and might take
        // traffic then -> the end is unknown.
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        let b = l.t11Add(.claude, "b")
        l.set(a, .fiveHour, used: 0, at: now)
        l.set(a, .weekly, used: 100, resets: t11("12:00", plusDays: 3), at: now)
        l.set(b, .fiveHour, used: 90, resets: t11("11:30"), at: t11("11:00"))
        l.set(b, .weekly, used: 100, resets: t11("12:00", plusDays: 1), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 60, now: now)
                == .insufficientData)
        #expect(LockoutSimulation.lockouts(.claude, ledger: l, demandPerHour: 60, now: now) == nil)

        // b's weekly resets 2026-11-26 12:00 instead, after a's 2026-11-25 12:00: the
        // end stands.
        l.set(b, .weekly, used: 100, resets: t11("12:00", plusDays: 4), at: now)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 60, now: now)
                == .lockout(from: t11("12:00"), to: t11("12:00", plusDays: 3)))
    }

    @Test func unknownAccountCoolingDownPastTheHorizonCanEndTheLockoutSooner() {
        // Item G, cooldown. team-a: 20 left (used 80), 5-hour reset 17:30. 120/h = 2 per
        // minute, all to team-a: 20 / 2 = 10 min -> empty at 12:10, still empty at 17:00,
        // recovers at its 17:30 reset. team-b: 5-hour unknown (ended 11:30, no proof),
        // cooling down until 17:05: left out (past 17:00), but 17:05 < 17:30 -> unknown end.
        func ledger(cooldown: Date, resetA: Date) -> T3FakeLedgerView {
            var l = T3FakeLedgerView()
            let a = l.t11Add(.go, "team-a")
            let b = l.t11Add(.go, "team-b", unavailable: [.coolingDown(until: cooldown)])
            l.set(a, .fiveHour, used: 80, resets: resetA, at: now)
            l.set(b, .fiveHour, used: 90, resets: t11("11:30"), at: t11("11:00"))
            l.routing[.ocgo] = t11Routing(.mostHeadroom)
            return l
        }
        #expect(LockoutSimulation.forecast(.go, ledger: ledger(cooldown: t11("17:05"), resetA: t11("17:30")),
                                           demandPerHour: 120, now: now) == .insufficientData)
        // Cooling down until 17:45, after 17:30: lockout 12:10 to 17:30.
        #expect(LockoutSimulation.forecast(.go, ledger: ledger(cooldown: t11("17:45"), resetA: t11("17:30")),
                                           demandPerHour: 120, now: now)
                == .lockout(from: t11("12:10"), to: t11("17:30")))
        // A lockout ending inside the horizon is unaffected: team-a resets at 15:00, so
        // the first lockout is 12:10 to 15:00 even with team-b back at 17:05.
        #expect(LockoutSimulation.forecast(.go, ledger: ledger(cooldown: t11("17:05"), resetA: t11("15:00")),
                                           demandPerHour: 120, now: now)
                == .lockout(from: t11("12:10"), to: t11("15:00")))
    }

    @Test func sessionAffinityWithholdsTheForecast() {
        var l = T3FakeLedgerView()
        let a = l.t11Add(.claude, "a")
        l.set(a, .fiveHour, used: 80, resets: t11("13:00"), at: now)
        l.routing[.cliproxy] = t11Routing(.roundRobin, affinity: true)
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .withheld(reason: "session affinity is on"))
        // Withheld even without a demand yet.
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: nil, now: now)
                == .withheld(reason: "session affinity is on"))

        l.routing = [:]
        #expect(LockoutSimulation.forecast(.claude, ledger: l, demandPerHour: 120, now: now)
                == .withheld(reason: "routing unknown"))
    }
}
