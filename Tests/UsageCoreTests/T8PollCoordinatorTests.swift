import Foundation
import Testing
import UsageCore

// T8 acceptance (docs/implementation-plan.md "T8. Poll coordinator", E13) on a real
// SQLite store and the real Ledger, with fake sources that record every call.
// Expected values come from the plan's text, not from running the coordinator.

private func t(_ hhmm: String) -> Date { date("2026-11-22T\(hhmm):00Z") }

private let claudeFile = "claude-1a2b3c4d-a@example.com.json"
private let codexFile = "codex-b@example.com.json"

private func claudeAccount(counter: Int = 100) -> AccountSnapshot {
    AccountSnapshot(id: AccountID(provider: .claude, identity: "1a2b3c4d"), fileKey: claudeFile,
                    email: "a@example.com", enabled: true, unavailable: [], requestCounter: counter,
                    routing: nil, polledAt: nil, pollError: nil)
}

private func reading(_ p: Provider, _ file: String, _ w: WindowKind = .fiveHour, used: Double = 40,
                     resets: Date? = nil, at: Date, source: ReadingSource) -> SourceReading {
    SourceReading(provider: p, fileKey: file, window: w, usedPercent: used, resetsAt: resets,
                  observedAt: at, source: source)
}

private func cliproxySnapshot(at: Date, accounts: [AccountSnapshot] = [claudeAccount()],
                              readings: [SourceReading]) -> SourceSnapshot {
    SourceSnapshot(source: .cliproxy, takenAt: at, accounts: accounts, readings: readings,
                   unclassified: [], routing: nil)
}

/// A credential list at the current time whose passive readings are observed then.
private func freshPassive(_ now: Date) -> Result<SourceSnapshot, SourceError> {
    .success(cliproxySnapshot(at: now, readings: [
        reading(.claude, claudeFile, at: now, source: .passive),
        reading(.codex, codexFile, at: now, source: .passive),
    ]))
}

private func forkResponse(_ providers: [Provider: ForkProviderState],
                          history: [SourceReading] = [], current: [SourceReading] = [])
    -> Result<ForkHistoryResponse, SourceError> {
    .success(ForkHistoryResponse(providers: providers, current: current, history: history))
}

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60

/// Ticks once a simulated minute, `count` times.
private func tickEveryMinute(_ rig: T8Rig, _ count: Int) async {
    for _ in 0..<count {
        rig.clock.advance(minute)
        await rig.coordinator.tick()
    }
}

/// Yields until `condition` holds (bounded; no real sleeping).
private func waitUntil(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@Suite("T8 poll coordinator")
struct T8PollCoordinatorTests {

    // MARK: Auth latch (E13)

    /// E13 resumed by a successful Test of the saved configuration.
    @Test func e13LatchesThenResumesAfterTestOfSavedConfig() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.isEmpty)   // the 401 tick skips fork history
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))

        await tickEveryMinute(rig, 10)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)   // nothing more in 10 minutes
        #expect(rig.log.historyRanges.isEmpty)
        #expect(rig.log.count(.fetch(.ocgo)) == 11)      // ocgo keeps polling

        rig.cliproxy.answer { .success(cliproxySnapshot(at: $0, readings: [])) }
        let result = await rig.coordinator.test(.cliproxy, T8Rig.cliproxyConfig)
        #expect(result == .success("ok"))
        #expect(rig.log.count(.test(.cliproxy, T8Rig.cliproxyConfig)) == 1)

        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) >= 2)
        #expect(!rig.log.historyRanges.isEmpty)
        let fetchesBefore = rig.log.count(.fetch(.cliproxy))
        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == fetchesBefore + 1)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .ok(at: rig.clock.now))
    }

    /// E13 resumed by `configChanged(.cliproxy)`.
    @Test func e13ResumesAfterConfigChanged() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 10)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.isEmpty)

        let newConfig = SourceConfig(url: T8Rig.cliproxyConfig.url, secret: "new-key")
        rig.configs.update { $0[.cliproxy] = newConfig }
        rig.cliproxy.answer { .success(cliproxySnapshot(at: $0, readings: [])) }
        await rig.coordinator.configChanged(.cliproxy)
        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) >= 2)
        #expect(!rig.log.historyRanges.isEmpty)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .ok(at: rig.clock.now))
    }

    /// On the 401 tick the fork history source gets no call: the tick's calls are
    /// the credential list and ocgo only.
    @Test func authErrorTickSendsNoHistoryRequest() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        let requests = rig.log.events.filter {
            switch $0 {
            case .fetch, .history, .test: true
            default: false
            }
        }
        #expect(requests.filter { $0 == .fetch(.cliproxy) }.count == 1)
        #expect(requests.filter { $0 == .fetch(.ocgo) }.count == 1)
        #expect(requests.count == 2)
    }

    @Test func testThatGets401SendsOneRequestAndStaysLatched() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        rig.cliproxy.testResult.set(.failure(.unauthorized))

        let result = await rig.coordinator.test(.cliproxy, T8Rig.cliproxyConfig)
        #expect(result == .failure(.unauthorized))
        #expect(rig.log.count(.test(.cliproxy, T8Rig.cliproxyConfig)) == 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)   // the Test made no fetch

        rig.cliproxy.answer { .success(cliproxySnapshot(at: $0, readings: [])) }
        await tickEveryMinute(rig, 3)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.isEmpty)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))
    }

    @Test func successfulTestOfUnsavedKeyStaysLatched() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()

        let unsaved = SourceConfig(url: T8Rig.cliproxyConfig.url, secret: "typed-not-saved")
        let result = await rig.coordinator.test(.cliproxy, unsaved)
        #expect(result == .success("ok"))
        #expect(rig.log.count(.test(.cliproxy, unsaved)) == 1)

        rig.cliproxy.answer { .success(cliproxySnapshot(at: $0, readings: [])) }
        await tickEveryMinute(rig, 3)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.isEmpty)
    }

    /// "a 403 latches the same way": every auth error latches, and stops fork history.
    @Test(arguments: [SourceError.unauthorized, .remoteManagementDisabled, .ipBanned])
    func everyAuthErrorLatches(_ error: SourceError) async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(error))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 5)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.isEmpty)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(error))
    }

    /// A non-auth failure doesn't latch: the tick still asks for history, and the next
    /// tick polls again.
    @Test func nonAuthFailureKeepsPolling() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.failure(.http(500)))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 2)
        #expect(rig.log.count(.fetch(.cliproxy)) == 3)
        #expect(rig.log.historyRanges.count == 3)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .failing(.http(500), since: t("12:00")))
    }

    /// The history route is a cliproxy request: its auth error latches cliproxy too.
    @Test func historyAuthErrorLatchesCliproxy() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.fork.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 3)
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.count == 1)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))
    }

    @Test func poolSettingsChangedWhileLatchedRepublishesWithNewStaleThreshold() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.success(cliproxySnapshot(at: t("12:00"), readings: [
            reading(.claude, claudeFile, used: 40, resets: t("16:00"), at: t("12:00"), source: .passive),
        ])))
        await rig.coordinator.tick()

        rig.clock.set(t("12:15"))
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        let before = try #require(await rig.coordinator.model?.row(.claude)?.fiveHour?.accounts.first)
        #expect(before.remaining == 60)
        #expect(before.stale == false)   // 15 minutes old, default threshold 30 min
        let fetches = rig.log.count(.fetch(.cliproxy))
        let historyRequests = rig.log.historyRanges.count

        await rig.coordinator.poolSettingsChanged(PoolSettings(staleAfter: 10 * minute))
        let model = try #require(await rig.coordinator.model)
        #expect(model.generatedAt == t("12:15"))
        let after = try #require(model.row(.claude)?.fiveHour?.accounts.first)
        #expect(after.stale == true)
        #expect(model.sources[.cliproxy] == .authStopped(.unauthorized))
        #expect(rig.log.count(.fetch(.cliproxy)) == fetches)
        #expect(rig.log.historyRanges.count == historyRequests)

        await tickEveryMinute(rig, 2)   // still latched
        #expect(rig.log.count(.fetch(.cliproxy)) == fetches)
    }

    @Test func failingOcgoDoesNotStopCliproxy() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.ocgo.answer(.failure(.unreachable))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 4)
        #expect(rig.log.count(.fetch(.cliproxy)) == 5)
        #expect(rig.log.historyRanges.count == 5)
        #expect(rig.log.count(.fetch(.ocgo)) == 5)
        let sources = try #require(await rig.coordinator.model?.sources)
        #expect(sources[.ocgo] == .failing(.unreachable, since: t("12:00")))
        #expect(sources[.cliproxy] == .ok(at: t("12:04")))
    }

    /// An ocgo auth error latches ocgo only.
    @Test func ocgoAuthErrorLatchesOcgoOnly() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.ocgo.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 3)
        #expect(rig.log.count(.fetch(.ocgo)) == 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == 4)
    }

    // MARK: Cadence

    @Test func fiveSimulatedMinutesSendFiveOfEachRequest() async throws {
        let db = T5TempDatabase()
        let start = t("12:00")
        let rig = try T8Rig(db: db, at: start) { clock in
            T8Scheduler(clock: clock, stopAt: start.addingTimeInterval(5 * minute))
        }
        let (power, _) = AsyncStream<PowerEvent>.makeStream()
        await rig.coordinator.run(power: power)
        #expect(rig.log.count(.fetch(.cliproxy)) == 5)
        #expect(rig.log.historyRanges.count == 5)
        #expect(rig.log.count(.fetch(.ocgo)) == 5)
        #expect(rig.clock.now == t("12:04"))
    }

    // MARK: History origin and range

    @Test func history404SwitchesEveryProviderToLocal() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        await rig.coordinator.tick()
        #expect(await rig.coordinator.historyOrigin(.claude) == .fork)
        #expect(await rig.coordinator.historyOrigin(.codex) == .fork)

        rig.fork.answer(.failure(.http(404)))
        await tickEveryMinute(rig, 1)
        #expect(await rig.coordinator.historyOrigin(.claude) == .local)
        #expect(await rig.coordinator.historyOrigin(.codex) == .local)
        #expect(await rig.coordinator.historyOrigin(.go) == .local)
        // A 404 isn't an auth error: cliproxy keeps polling.
        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == 3)
    }

    @Test func pausedCodexSwitchesCodexToLocal() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.fork.answer(forkResponse([.claude: .served, .codex: .paused]))
        await rig.coordinator.tick()
        #expect(await rig.coordinator.historyOrigin(.claude) == .fork)
        #expect(await rig.coordinator.historyOrigin(.codex) == .local)
        #expect(await rig.coordinator.historyOrigin(.go) == .local)
    }

    @Test func noForkSourceMeansLocalHistory() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), withFork: false)
        await rig.coordinator.tick()
        #expect(rig.log.historyRanges.isEmpty)
        #expect(await rig.coordinator.historyOrigin(.claude) == .local)
    }

    @Test func firstLaunchOnEmptyStoreAsksFor24h() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("13:00"))
        await rig.coordinator.tick()
        #expect(rig.log.historyRanges == [24 * hour])
    }

    /// Sleep 10:00 to 13:00, last fork observation 09:59; the first credential list
    /// after wake brings fresh passive readings, which don't count.
    @Test func wakeAsksForRangeSinceLastForkObservation() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("09:59"))
        rig.fork.answer(forkResponse([.claude: .served, .codex: .served], history: [
            reading(.claude, claudeFile, at: t("09:59"), source: .forkPoller),
            reading(.codex, codexFile, at: t("09:59"), source: .forkPoller),
        ]))
        await rig.coordinator.tick()

        await rig.coordinator.handle(.willSleep(at: t("10:00")))
        rig.clock.set(t("13:00"))
        await rig.coordinator.handle(.didWake(at: t("13:00")))
        #expect(rig.log.gaps == [DateInterval(start: t("10:00"), end: t("13:00"))])

        rig.cliproxy.answer(freshPassive)
        rig.fork.answer(forkResponse([.claude: .served, .codex: .served]))
        await rig.coordinator.tick()
        #expect(rig.log.historyRanges.last == 3 * hour + minute)   // 3h01m
        #expect(try rig.store.lastObservation(.claude, source: .passive) == t("13:00"))
    }

    /// A first coordinator stores fork observations (Claude 09:59, Codex 09:50, both
    /// served) and is discarded; a fresh one on the same store at 13:00 asks for 3h10m.
    @Test func relaunchUsesStoredForkObservations() async throws {
        let db = T5TempDatabase()
        do {
            let first = try T8Rig(db: db, at: t("09:59"))
            first.fork.answer(forkResponse([.claude: .served, .codex: .served], history: [
                reading(.claude, claudeFile, at: t("09:59"), source: .forkPoller),
                reading(.codex, codexFile, at: t("09:50"), source: .forkPoller),
            ]))
            await first.coordinator.tick()
            (first.store.base as? SQLiteHistoryStore)?.close()
        }

        let fresh = try T8Rig(db: db, at: t("13:00"))
        fresh.cliproxy.answer(freshPassive)
        await fresh.coordinator.tick()
        #expect(fresh.log.historyRanges.first == 3 * hour + 10 * minute)
        // Passive readings were stored before the history request.
        let events = fresh.log.events
        let firstHistory = try #require(events.firstIndex { if case .history = $0 { true } else { false } })
        #expect(events.prefix(firstHistory).contains(.append(count: 2)))
    }

    /// Paused variant: a second response marks Codex paused with no Codex history; the
    /// store keeps Codex's 09:50 observation, and the fresh coordinator asks for 3h01m.
    @Test func relaunchAfterCodexPausedUsesClaudeOnly() async throws {
        let db = T5TempDatabase()
        do {
            let first = try T8Rig(db: db, at: t("09:59"))
            first.fork.answer(forkResponse([.claude: .served, .codex: .served], history: [
                reading(.claude, claudeFile, at: t("09:59"), source: .forkPoller),
                reading(.codex, codexFile, at: t("09:50"), source: .forkPoller),
            ]))
            await first.coordinator.tick()
            first.clock.set(t("10:00"))
            first.fork.answer(forkResponse([.claude: .served, .codex: .paused], history: [
                reading(.claude, claudeFile, at: t("09:59"), source: .forkPoller),
            ]))
            await first.coordinator.tick()
            #expect(try first.store.lastObservation(.codex, source: .forkPoller) == t("09:50"))
            (first.store.base as? SQLiteHistoryStore)?.close()
        }

        let fresh = try T8Rig(db: db, at: t("13:00"))
        await fresh.coordinator.start()
        // Before any request, the stored provider states choose the history origin.
        #expect(await fresh.coordinator.historyOrigin(.claude) == .fork)
        #expect(await fresh.coordinator.historyOrigin(.codex) == .local)
        fresh.cliproxy.answer(freshPassive)
        await fresh.coordinator.tick()
        #expect(fresh.log.historyRanges.first == 3 * hour + minute)
    }

    @Test func rangeIsClampedToOneHourAndSevenHundredTwentyHours() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("13:00"))
        rig.fork.answer(forkResponse([.claude: .served], history: [
            reading(.claude, claudeFile, at: t("12:50"), source: .forkPoller),
        ]))
        await rig.coordinator.tick()
        await tickEveryMinute(rig, 1)
        #expect(rig.log.historyRanges.last == hour)   // 11 minutes -> 1h

        let db2 = T5TempDatabase()
        let old = try T8Rig(db: db2, at: t("13:00"))
        old.fork.answer(forkResponse([.claude: .served], history: [
            reading(.claude, claudeFile, at: t("13:00").addingTimeInterval(-31 * 24 * hour),
                    source: .forkPoller),
        ]))
        await old.coordinator.tick()
        await tickEveryMinute(old, 1)
        #expect(old.log.historyRanges.last == 720 * hour)   // 31 days -> 720h
    }

    // MARK: Gaps

    /// The gap uses the times the events carry, not the time they're handled.
    @Test func sleepFrom13To14StoresThatGap() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:59"))
        await rig.coordinator.tick()
        rig.clock.set(t("14:05"))   // handled late
        await rig.coordinator.handle(.willSleep(at: t("13:00")))
        await rig.coordinator.handle(.didWake(at: t("14:00")))
        let gap = DateInterval(start: t("13:00"), end: t("14:00"))
        #expect(rig.log.gaps == [gap])
        #expect(try rig.store.gaps(since: t("12:00")) == [gap])
    }

    /// A second `.willSleep` keeps the first start; a wake at or before the sleep time
    /// stores no gap; a wake without a sleep stores nothing.
    @Test func sleepEdgeCases() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:59"))
        await rig.coordinator.start()
        await rig.coordinator.handle(.willSleep(at: t("13:00")))
        await rig.coordinator.handle(.willSleep(at: t("13:30")))
        await rig.coordinator.handle(.didWake(at: t("14:00")))
        #expect(rig.log.gaps == [DateInterval(start: t("13:00"), end: t("14:00"))])

        await rig.coordinator.handle(.willSleep(at: t("15:00")))
        await rig.coordinator.handle(.didWake(at: t("14:59")))   // clock stepped back
        #expect(await rig.coordinator.isAsleep == false)
        await rig.coordinator.handle(.didWake(at: t("16:00")))
        #expect(rig.log.gaps.count == 1)
    }

    /// The same, with the events arriving through `run(power:)`'s async sequence.
    @Test func powerEventsThroughRunStoreTheGap() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:59"))
        let (power, events) = AsyncStream<PowerEvent>.makeStream()
        let coordinator = rig.coordinator
        let running = Task { await coordinator.run(power: power) }
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 1 })

        events.yield(.willSleep(at: t("13:00")))
        #expect(await waitUntil { await coordinator.isAsleep })
        events.yield(.didWake(at: t("14:00")))
        #expect(await waitUntil { await !coordinator.isAsleep })
        running.cancel()
        await running.value
        #expect(rig.log.gaps == [DateInterval(start: t("13:00"), end: t("14:00"))])
    }

    /// B: the loop sends nothing between `.willSleep` and `.didWake`, and stores the
    /// gap before the first fetch after wake.
    @Test func loopSendsNothingWhileAsleep() async throws {
        let db = T5TempDatabase()
        let start = t("12:00")
        let target = T8Box<PollCoordinator?>(nil)
        let rig = try T8Rig(db: db, at: start) { clock in
            // Sleep at the 12:02 deadline, before that tick runs.
            T8Scheduler(clock: clock, stopAt: t("15:01")) { deadline in
                if deadline == t("12:02") { await target.get?.handle(.willSleep(at: t("12:02"))) }
            }
        }
        target.set(rig.coordinator)
        let (power, events) = AsyncStream<PowerEvent>.makeStream()
        let coordinator = rig.coordinator
        let running = Task { await coordinator.run(power: power) }

        #expect(await waitUntil { await coordinator.isAsleep })
        for _ in 0..<1_000 { await Task.yield() }   // give a wrong loop room to tick
        #expect(rig.log.count(.fetch(.cliproxy)) == 2)   // 12:00 and 12:01 only
        #expect(rig.log.count(.fetch(.ocgo)) == 2)
        #expect(rig.log.historyRanges.count == 2)

        rig.clock.set(t("15:00"))
        events.yield(.didWake(at: t("15:00")))
        await running.value   // one tick at 15:00, then the scheduler stops at 15:01
        #expect(rig.log.count(.fetch(.cliproxy)) == 3)
        let log = rig.log.events
        let gap = try #require(log.firstIndex(of: .recordGap(DateInterval(start: t("12:02"), end: t("15:00")))))
        let fetches = log.indices.filter { log[$0] == .fetch(.cliproxy) }
        #expect(gap < fetches[2])
        let lastModel = try #require(await coordinator.model)
        #expect(lastModel.generatedAt == t("15:00"))
    }

    /// B: a `.willSleep` that arrives while the credential list is in flight stops the
    /// tick before fork history.
    @Test func sleepDuringCredentialFetchSkipsHistory() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        let gate = T8Gate()
        rig.cliproxy.gate.set(gate)
        let coordinator = rig.coordinator
        let ticking = Task { await coordinator.tick() }
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 1 })
        await coordinator.handle(.willSleep(at: t("12:00")))
        gate.open()
        await ticking.value
        #expect(rig.log.historyRanges.isEmpty)
    }

    @Test func launchRecordsGapFromLastStoredPoll() async throws {
        let db = T5TempDatabase()
        do {
            let first = try T8Rig(db: db, at: t("09:59"))
            await first.coordinator.tick()
            (first.store.base as? SQLiteHistoryStore)?.close()
        }
        let fresh = try T8Rig(db: db, at: t("13:00"))
        await fresh.coordinator.start()
        #expect(fresh.log.gaps == [DateInterval(start: t("09:59"), end: t("13:00"))])
        // The restored statuses show the last poll time.
        #expect(await fresh.coordinator.model?.sources[.cliproxy] == .ok(at: t("09:59")))
    }

    // MARK: Store and ledger

    @Test func persistsEachSnapshotInOrderThenApplies() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        rig.cliproxy.answer(.success(cliproxySnapshot(at: t("12:00"), readings: [
            reading(.claude, claudeFile, .fiveHour, at: t("12:00"), source: .passive),
            reading(.claude, claudeFile, .weekly, at: t("12:00"), source: .passive),
            reading(.claude, claudeFile, .monthly, at: t("12:00"), source: .passive),
        ])))
        rig.fork.answer(forkResponse([.claude: .served], history: [
            reading(.claude, claudeFile, at: t("11:00"), source: .forkPoller),
            reading(.claude, claudeFile, at: t("11:05"), source: .forkPoller),
            reading(.claude, claudeFile, at: t("11:10"), source: .forkPoller),
            reading(.claude, claudeFile, at: t("11:15"), source: .forkPoller),
        ], current: [
            reading(.claude, claudeFile, .fiveHour, at: t("11:58"), source: .forkPoller),
            reading(.claude, claudeFile, .weekly, at: t("11:58"), source: .forkPoller),
        ]))
        await rig.coordinator.tick()

        let events = rig.log.events
        #expect(Array(events.prefix(5)) == [
            .fetch(.cliproxy), .append(count: 3), .appendCounterMarks, .saveLastSnapshot(.cliproxy),
            .applySnapshot(.cliproxy),
        ])
        let appendCurrent = try #require(events.firstIndex(of: .append(count: 2)))
        let applyCurrent = try #require(events.firstIndex(of: .applyReadings(count: 2)))
        #expect(appendCurrent < applyCurrent)
        #expect(events.contains(.append(count: 4)))      // history is stored
        #expect(events.contains(.saveForkProviderStates))
        #expect(try rig.store.counterMarks(since: .distantPast)
                == [CounterMark(fileKey: claudeFile, at: t("12:00"), value: 100)])
        #expect(try rig.store.forkProviderStates() == [.claude: .served])
    }

    /// A snapshot whose `takenAt` isn't after the last accepted one is neither stored
    /// nor applied.
    @Test func snapshotNotNewerThanLastAcceptedIsDiscarded() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        rig.cliproxy.answer(.success(cliproxySnapshot(at: t("12:00"), readings: [
            reading(.claude, claudeFile, used: 40, at: t("12:00"), source: .passive),
        ])))
        await rig.coordinator.tick()

        for takenAt in [t("12:00"), t("11:59")] {   // same time, then a clock correction
            rig.cliproxy.answer(.success(cliproxySnapshot(at: takenAt, readings: [
                reading(.claude, claudeFile, used: 90, at: takenAt, source: .passive),
            ])))
            await tickEveryMinute(rig, 1)
        }
        #expect(rig.log.count(.fetch(.cliproxy)) == 3)
        #expect(rig.log.count(.saveLastSnapshot(.cliproxy)) == 1)
        #expect(rig.log.count(.applySnapshot(.cliproxy)) == 1)
        #expect(rig.log.count(.appendCounterMarks) == 1)
        let id = AccountID(provider: .claude, identity: "1a2b3c4d")
        #expect(rig.ledger.latest(id, .fiveHour)?.reading.usedPercent == 40)
        // The store holds only the accepted 12:00 reading.
        #expect(try rig.store.readings(fileKeys: [claudeFile], .fiveHour, from: .distantPast,
                                       to: .distantFuture)
                == [reading(.claude, claudeFile, used: 40, at: t("12:00"), source: .passive)])
    }

    // MARK: Requests in flight

    /// A: a Test of the saved configuration that gets an auth error latches at once; a
    /// Test of an unsaved one doesn't.
    @Test func testOfSavedConfigThatGetsAuthErrorLatches() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        await rig.coordinator.tick()
        rig.cliproxy.testResult.set(.failure(.unauthorized))

        let unsaved = SourceConfig(url: T8Rig.cliproxyConfig.url, secret: "typed-not-saved")
        #expect(await rig.coordinator.test(.cliproxy, unsaved) == .failure(.unauthorized))
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .ok(at: t("12:00")))
        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == 2)

        #expect(await rig.coordinator.test(.cliproxy, T8Rig.cliproxyConfig) == .failure(.unauthorized))
        #expect(rig.log.count(.test(.cliproxy, T8Rig.cliproxyConfig)) == 1)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))
        await tickEveryMinute(rig, 3)
        #expect(rig.log.count(.fetch(.cliproxy)) == 2)
        #expect(rig.log.historyRanges.count == 2)
        #expect(rig.log.count(.fetch(.ocgo)) == 5)
    }

    /// A: a credential list that comes back after a Test latched cliproxy is dropped and
    /// doesn't go on to fork history.
    @Test func fetchInFlightWhenTestLatchesStopsBeforeHistory() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        let gate = T8Gate()
        rig.cliproxy.gate.set(gate)
        let coordinator = rig.coordinator
        let ticking = Task { await coordinator.tick() }
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 1 })

        rig.cliproxy.testResult.set(.failure(.unauthorized))
        _ = await coordinator.test(.cliproxy, T8Rig.cliproxyConfig)
        gate.open()
        await ticking.value
        #expect(rig.log.historyRanges.isEmpty)
        #expect(rig.log.count(.applySnapshot(.cliproxy)) == 0)
        #expect(await coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))
    }

    /// D: settings go A -> B -> A while a credential list for A is in flight; its
    /// answer is from before the change and is dropped.
    @Test func answerFromBeforeConfigChangesIsDroppedEvenWhenConfigComesBack() async throws {
        let db = T5TempDatabase()
        let configA = T8Rig.cliproxyConfig
        let configB = SourceConfig(url: configA.url, secret: "other-key")
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: configA])
        rig.cliproxy.answer(.success(cliproxySnapshot(at: t("12:00"), readings: [
            reading(.claude, claudeFile, used: 90, at: t("12:00"), source: .passive),
        ])))
        let gate = T8Gate()
        rig.cliproxy.gate.set(gate)
        let coordinator = rig.coordinator
        let ticking = Task { await coordinator.tick() }
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 1 })

        rig.configs.update { $0[.cliproxy] = configB }
        await coordinator.configChanged(.cliproxy)
        rig.configs.update { $0[.cliproxy] = configA }
        await coordinator.configChanged(.cliproxy)
        rig.clock.set(date("2026-11-22T12:00:30Z"))
        rig.cliproxy.answer { now in
            .success(cliproxySnapshot(at: now, readings: [
                reading(.claude, claudeFile, used: 20, at: now, source: .passive),
            ]))
        }
        gate.open()
        await ticking.value   // also runs the poll the config changes asked for

        #expect(rig.log.count(.fetch(.cliproxy)) == 2)
        #expect(rig.log.count(.saveLastSnapshot(.cliproxy)) == 1)
        #expect(rig.log.count(.applySnapshot(.cliproxy)) == 1)
        #expect(rig.log.historyRanges.count == 1)   // only after the current answer
        #expect(try rig.store.readings(fileKeys: [claudeFile], .fiveHour, from: .distantPast,
                                       to: .distantFuture)
                == [reading(.claude, claudeFile, used: 20, at: date("2026-11-22T12:00:30Z"),
                            source: .passive)])
    }

    /// E: a config change while another source's poll is in flight keeps the cliproxy
    /// status, so the publish at the end of that poll still has the provider rows.
    @Test func configChangeDuringInFlightPollKeepsProviderRows() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer { now in
            .success(cliproxySnapshot(at: now, readings: [
                reading(.claude, claudeFile, used: 40, resets: t("16:00"), at: now, source: .passive),
            ]))
        }
        await rig.coordinator.tick()
        #expect(await rig.coordinator.model?.row(.claude) != nil)

        rig.clock.set(t("12:01"))
        let gate = T8Gate()
        rig.ocgo.gate.set(gate)
        let coordinator = rig.coordinator
        let ticking = Task { await coordinator.tick() }
        #expect(await waitUntil {
            rig.log.count(.fetch(.ocgo)) == 2 && rig.log.historyRanges.count == 2
        })

        let before = rig.published.get.count
        rig.configs.update { $0[.cliproxy] = SourceConfig(url: T8Rig.cliproxyConfig.url, secret: "new-key") }
        await coordinator.configChanged(.cliproxy)
        gate.open()
        await ticking.value
        let after = Array(rig.published.get.dropFirst(before))
        #expect(after.count >= 2)
        for model in after {
            #expect(model.row(.claude) != nil)
            #expect(model.sources[.cliproxy] != nil)
        }
    }

    @Test func storeErrorDoesNotStopLedgerOrNextTick() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        rig.store.failing.set(["append", "appendCounterMarks", "saveLastSnapshot", "saveForkProviderStates"])
        rig.cliproxy.answer { now in
            .success(cliproxySnapshot(at: now, readings: [
                reading(.claude, claudeFile, used: 30, resets: t("16:00"), at: now, source: .passive),
            ]))
        }
        await rig.coordinator.tick()
        #expect(await rig.coordinator.lastStoreError != nil)
        #expect(rig.log.count(.applySnapshot(.cliproxy)) == 1)
        let remaining = await rig.coordinator.model?.row(.claude)?.fiveHour?.accounts.first?.remaining
        #expect(remaining == 70)

        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == 2)
        #expect(rig.log.count(.applySnapshot(.cliproxy)) == 2)
        #expect(rig.log.historyRanges.count == 2)
    }

    /// The loop prunes to 30 days once a day (the store also prunes on open).
    @Test func prunesOnceADay() async throws {
        let db = T5TempDatabase()
        let start = t("12:00")
        let rig = try T8Rig(db: db, at: start)
        await rig.coordinator.tick()
        rig.clock.set(start.addingTimeInterval(24 * hour - minute))
        await rig.coordinator.tick()
        #expect(rig.log.prunes.isEmpty)

        let day = start.addingTimeInterval(24 * hour)
        rig.clock.set(day)
        await rig.coordinator.tick()
        #expect(rig.log.prunes == [day.addingTimeInterval(-30 * 24 * hour)])

        rig.clock.set(day.addingTimeInterval(23 * hour))
        await rig.coordinator.tick()
        #expect(rig.log.prunes.count == 1)
        rig.clock.set(day.addingTimeInterval(24 * hour))
        await rig.coordinator.tick()
        #expect(rig.log.prunes == [day.addingTimeInterval(-30 * 24 * hour),
                                   day.addingTimeInterval(24 * hour - 30 * 24 * hour)])
    }

    /// G: a 401 from a credential list that started before a Test latched and a second
    /// Test cleared the latch doesn't latch again.
    @Test func late401FromBeforeTestClearedTheLatchIsDropped() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        rig.cliproxy.answer(.failure(.unauthorized))
        let gate = T8Gate()
        rig.cliproxy.gate.set(gate)
        let coordinator = rig.coordinator
        let ticking = Task { await coordinator.tick() }
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 1 })

        rig.cliproxy.testResult.set(.failure(.unauthorized))
        _ = await coordinator.test(.cliproxy, T8Rig.cliproxyConfig)   // latches
        rig.cliproxy.testResult.set(.success("ok"))
        _ = await coordinator.test(.cliproxy, T8Rig.cliproxyConfig)   // clears; poll queued
        rig.cliproxy.answer { .success(cliproxySnapshot(at: $0, readings: [])) }
        gate.open()           // the first request's 401 arrives now
        await ticking.value   // then the queued poll runs

        #expect(rig.log.count(.fetch(.cliproxy)) == 2)
        #expect(rig.log.historyRanges.count == 1)
        #expect(await coordinator.model?.sources[.cliproxy] == .ok(at: t("12:00")))
        await tickEveryMinute(rig, 1)
        #expect(rig.log.count(.fetch(.cliproxy)) == 3)
    }

    /// H: a poll queued before sleep (here by a config change during a tick) sends
    /// nothing once `.willSleep` has arrived.
    @Test func queuedPollSendsNothingWhileAsleep() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        let gate = T8Gate()
        rig.cliproxy.gate.set(gate)
        let coordinator = rig.coordinator
        let ticking = Task { await coordinator.tick() }
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 1 })

        rig.configs.update { $0[.ocgo] = T8Rig.ocgoConfig }
        await coordinator.configChanged(.ocgo)   // queued behind the running tick
        await coordinator.handle(.willSleep(at: t("12:00")))
        gate.open()
        await ticking.value
        #expect(rig.log.count(.fetch(.ocgo)) == 0)
        #expect(rig.log.historyRanges.isEmpty)
    }

    /// H: a wake followed by another sleep before the loop runs again keeps the loop
    /// waiting: no tick, no publish, the clock doesn't move.
    @Test func wakeThenSleepAgainKeepsTheLoopWaiting() async throws {
        let db = T5TempDatabase()
        let target = T8Box<PollCoordinator?>(nil)
        let rig = try T8Rig(db: db, at: t("12:00")) { clock in
            T8Scheduler(clock: clock, stopAt: t("18:00")) { deadline in
                if deadline == t("12:02") { await target.get?.handle(.willSleep(at: t("12:02"))) }
            }
        }
        target.set(rig.coordinator)
        let coordinator = rig.coordinator
        let (power, events) = AsyncStream<PowerEvent>.makeStream()
        let running = Task { await coordinator.run(power: power) }
        #expect(await waitUntil { await coordinator.isAsleep })
        let published = rig.published.get.count

        // The Mac goes back to sleep inside the wake handling, before the loop resumes.
        rig.store.onRecordGap.set {
            coordinator.assumeIsolated { $0.handle(.willSleep(at: t("13:01"))) }
        }
        rig.clock.set(t("13:00"))
        events.yield(.didWake(at: t("13:00")))
        #expect(await waitUntil { rig.log.gaps.count == 1 })
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await coordinator.isAsleep)
        #expect(rig.published.get.count == published)
        #expect(rig.clock.now == t("13:00"))
        #expect(rig.log.count(.fetch(.cliproxy)) == 2)

        rig.store.onRecordGap.set(nil)
        running.cancel()
        await running.value
    }

    /// I: when the power events end while asleep, the loop goes on (no gap) instead of
    /// waiting forever.
    @Test func powerStreamEndingWhileAsleepReleasesTheLoop() async throws {
        let db = T5TempDatabase()
        let target = T8Box<PollCoordinator?>(nil)
        let rig = try T8Rig(db: db, at: t("12:00")) { clock in
            T8Scheduler(clock: clock, stopAt: t("12:03")) { deadline in
                if deadline == t("12:02") { await target.get?.handle(.willSleep(at: t("12:02"))) }
            }
        }
        target.set(rig.coordinator)
        let coordinator = rig.coordinator
        let (power, events) = AsyncStream<PowerEvent>.makeStream()
        let running = Task { await coordinator.run(power: power) }
        #expect(await waitUntil { await coordinator.isAsleep })

        events.finish()
        // The 12:02 tick runs, then the scheduler stops the loop at 12:03.
        #expect(await waitUntil { rig.log.count(.fetch(.cliproxy)) == 3 })
        running.cancel()   // only matters when the loop is stuck
        await running.value
        #expect(await !coordinator.isAsleep)
        #expect(rig.log.gaps.isEmpty)
    }

    /// J: a Test before the first tick that latches cliproxy keeps `.authStopped`
    /// through `start()`'s restore of the last snapshot.
    @Test func startKeepsAuthStoppedFromAnEarlierTest() async throws {
        let db = T5TempDatabase()
        do {
            let first = try T8Rig(db: db, at: t("09:59"))
            await first.coordinator.tick()
            (first.store.base as? SQLiteHistoryStore)?.close()
        }
        let fresh = try T8Rig(db: db, at: t("13:00"))
        fresh.cliproxy.testResult.set(.failure(.unauthorized))
        _ = await fresh.coordinator.test(.cliproxy, T8Rig.cliproxyConfig)
        await fresh.coordinator.tick()
        #expect(await fresh.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))
        #expect(fresh.log.count(.fetch(.cliproxy)) == 0)
        #expect(await fresh.coordinator.model?.sources[.ocgo] == .ok(at: t("13:00")))
    }

    // MARK: Publishing and configuration

    @Test func publishesModelsOnTheStream() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"))
        rig.cliproxy.answer(.success(cliproxySnapshot(at: t("12:00"), readings: [
            reading(.claude, claudeFile, used: 25, resets: t("16:00"), at: t("12:00"), source: .passive),
        ])))
        await rig.coordinator.tick()
        var iterator = rig.coordinator.models.makeAsyncIterator()
        let model = try #require(await iterator.next())
        #expect(model.row(.claude)?.fiveHour?.accounts.first?.remaining == 75)
        #expect(model.sources == [.cliproxy: .ok(at: t("12:00")), .ocgo: .ok(at: t("12:00"))])
    }

    @Test func unconfiguredSourceIsNeverPolled() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t("12:00"), configs: [.cliproxy: T8Rig.cliproxyConfig])
        await rig.coordinator.tick()
        #expect(rig.log.count(.fetch(.ocgo)) == 0)
        #expect(await rig.coordinator.model?.sources[.ocgo] == .notConfigured)

        rig.configs.update { $0[.ocgo] = T8Rig.ocgoConfig }
        await rig.coordinator.configChanged(.ocgo)
        #expect(rig.log.count(.fetch(.ocgo)) == 1)
        #expect(await rig.coordinator.model?.sources[.ocgo] == .ok(at: t("12:00")))
    }
}
