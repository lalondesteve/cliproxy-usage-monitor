# usage-monitor implementation plan

Status: 2026-11-22. Implements the design in [plan.md](plan.md) (Phases 0 to 3). The
design is the source of truth for behavior; this file covers order, contracts, tasks
and checks. Nothing is built yet.

## What was checked on lals-mini

- The Swift toolchain works only with Xcode selected. The active developer directory
  is the Command Line Tools, where `swift build` works but `swift test` doesn't:
  XCTest is missing and the swift-testing macro plugin isn't found. With
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Xcode 27.2, Swift 6.4.2),
  a SwiftPM package builds, and both swift-testing and XCTest tests pass. The
  Makefile sets that variable, so nobody needs `sudo xcode-select`.
- From a SwiftPM executable target: `import SQLite3`, `import Security` and
  `NSStatusBar` link and run.
- `NSImage` loads every SVG in `assets/logos/` and `assets/icons/compact.svg`
  (`_NSSVGImageRep`), so the menubar can use them as template images with no
  conversion step.
- `thearch` and `cliproxy` give "No route to host" over SSH from this Mac. Phase 0
  can't run from here today.

## Assumptions not verified

Each one is checked by the named task. Until then, code follows the shapes documented
in plan.md.

| Assumption | Checked by |
|---|---|
| Payload shapes match plan.md (credential list, `quota.signals`, fork `quota/history`, routing, `/_ocgo/status`). No fixtures exist yet. | P0.2, P0.3 |
| `quota.signals` values are strings (they might be string arrays, like Go's `http.Header`) | P0.2 |
| The fork's `quota/history` `account.id` equals the credential list's `id` (the `fileKey`) | P0.2 |
| `success` and `failed` are cumulative counters that reset only when cliproxy restarts | P0.2 |
| The 403 bodies for "remote management disabled" and "IP banned" can be told apart | P0.2 |
| The live VM serves `GET /v8/management/quota/history` | P0.3 |
| The Mac can reach the NetBird addresses of both proxies | P0.3, T10 |
| Keychain items stay readable without a prompt after an ad-hoc-signed rebuild | T1 |
| Stale threshold: plan.md doesn't give a value. Default 30 min, editable in Settings | Confirm with the user at T9b review |

## Repository layout and ownership

```
Package.swift                      integrator
Makefile                           integrator   (test, app, run; sets DEVELOPER_DIR)
scripts/bundle.sh                  T1           (wraps the binary into UsageMonitor.app)
scripts/capture-fixtures.sh        T2
Sources/UsageCore/                 Foundation + SQLite3 + Security only, no AppKit
  Contracts/                       integrator   (types below; changes go through the integrator)
  Sources/Ocgo*.swift              T1, then T7
  Sources/Cliproxy*.swift          T6
  Ledger.swift                     T4
  Pool/                            T3
  Store/                           T5
  Polling/                         T8
  Forecast/                        T11
Sources/UsageMonitorApp/           AppKit + SwiftUI
  AppDelegate.swift, Wiring.swift  integrator   (composition root)
  StatusItem/                      T9a
  Dropdown/                        T9b
  Setup/, Keychain.swift           T9c
Tests/UsageCoreTests/
  Fixtures/live/                   P0.3 (sanitized captures) + EXPECTED.md worksheet
  Fixtures/synthetic/<task>/       each task owns its folder
Tests/UsageMonitorAppTests/        layout and state-machine tests for T9
```

The integrator is the main agent. Task agents don't edit `Contracts/`, `Package.swift`
or the composition root. When a contract needs a change, they stop and report it with
the reason.

## Contracts

T1 settles these, and they are frozen after its review. Sketches, not final code:

```swift
// Identity and units
enum Provider: String, Codable, CaseIterable { case claude, codex, go }
enum WindowKind: String, Codable { case fiveHour, weekly, monthly }
struct AccountID: Hashable, Codable { let provider: Provider; let identity: String }
enum SourceKind { case cliproxy, ocgo }
enum ReadingSource: String, Codable { case passive, forkPoller, ocgo, active }

// What sources emit and the store persists: keyed by credential file, never by a
// resolved account. fileKey = the credential list's `id` (its file name), which the
// fork's quota/history `account.id` also uses; for ocgo, the account name.
struct SourceReading: Codable, Equatable {
  let provider: Provider
  let fileKey: String
  let window: WindowKind
  let usedPercent: Double   // 0...100, converted and clamped by the parser
                            // (Claude fraction x100; fork "remaining" -> 100 - x)
  let resetsAt: Date?       // nil = unset: missing, epoch 0, or 0001-01-01T00:00:00Z
  let observedAt: Date
  let source: ReadingSource
}
// What the ledger returns: the same reading with its account resolved at read time
// from the latest credential list and the Settings alias list.
struct WindowReading: Equatable { let account: AccountID; let reading: SourceReading }
struct UnclassifiedReading { let provider: Provider; let fileKey: String; let lengthSeconds: Int?
                             let usedPercent: Double; let resetsAt: Date?; let observedAt: Date }

enum Unavailability: Codable, Equatable {
  case upstreamUnavailable              // cliproxy `unavailable`
  case outOfRotation                    // weight <= 0 under weighted-round-robin
  case exhausted(until: Date?), coolingDown(until: Date?)   // ocgo
  case notForcedAccount                 // ocgo forced_account names another account
}
struct AccountRouting { let priority: Int; let weight: Int }
struct AccountSnapshot {                // one per credential file or ocgo account
  let id: AccountID                     // identity rule from plan.md "Identity", before the alias list
  let fileKey: String                   // credential name or ocgo account name
  let email: String?
  let enabled: Bool
  let unavailable: [Unavailability]     // empty = the source calls it available
  let requestCounter: Int?              // cliproxy success + failed; nil for ocgo
  let routing: AccountRouting?
  let polledAt: Date?, pollError: String?   // ocgo
}
struct RoutingConfig {
  enum Strategy { case roundRobin, weightedRoundRobin, fillFirst, mostHeadroom }
  let strategy: Strategy; let sessionAffinity: Bool; let forcedAccount: AccountID?
}
struct SourceSnapshot {
  let source: SourceKind; let takenAt: Date
  let accounts: [AccountSnapshot]; let readings: [SourceReading]
  let unclassified: [UnclassifiedReading]; let routing: RoutingConfig?
}

// Seams
protocol HTTPTransport: Sendable { func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) }
protocol NowProvider: Sendable { var now: Date { get } }
enum SourceError: Error, Equatable {
  case unauthorized, remoteManagementDisabled, ipBanned, tlsUntrusted, timeout,
       unreachable, http(Int), decoding(String)
}
struct SourceConfig: Equatable { let url: URL; let secret: String? }
protocol UsageSource: Sendable {        // T6 and T7 implement
  var kind: SourceKind { get }
  // Requests run one after another; the first auth error (unauthorized,
  // remoteManagementDisabled, ipBanned) returns at once with no further request.
  func fetch(since: Date?) async -> Result<SourceSnapshot, SourceError>
  func test(_ config: SourceConfig) async -> Result<String, SourceError>   // exactly one request, never retried
}
enum ForkProviderState { case served, paused }   // paused: accounts show status "paused"
struct ForkHistoryResponse {            // one GET quota/history covers every provider
  let providers: [Provider: ForkProviderState]
  let current: [SourceReading]          // accounts[].reading.windows
  let history: [SourceReading]          // pools[].history, deduplicated, status "ok" only
}
protocol ForkHistorySource: Sendable {  // T6
  func fetch(range: TimeInterval) async -> Result<ForkHistoryResponse, SourceError>  // nil-route -> .http(404)
}

// Coordinator controls, T8 implements, T9c calls
protocol PollControl: Sendable {
  // One request with the given values. Clears the auth latch only when `config`
  // equals the saved configuration; a failure never clears it.
  func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError>
  func configChanged(_ kind: SourceKind) async   // only when that source's URL or secret changed; clears its latch
  func poolSettingsChanged(_ settings: PoolSettings) async   // updates the ledger and the settings passed to
                                                             // PoolEngine, then republishes; no latch change
}

// Settings (T9c edits, T3 and T9a read)
enum MenubarStyle: String, Codable { case normal, compact }
struct PoolSettings: Codable, Equatable { var staleAfter: TimeInterval = 1800
                                          var identityAliases: [String: String] = [:] }   // fileKey -> canonical identity
struct AppSettings: Codable, Equatable { var cliproxyURL: URL?; var ocgoURL: URL?
  var menubarStyle: MenubarStyle = .normal; var pool = PoolSettings()
  var activeCallsEnabled = false }      // secrets live in the Keychain, not here

// Persistence, used by T4 (restore), T8 (writes) and T11 (history). T5 implements.
// T8 persists source output unchanged; nothing in the store depends on the alias list.
protocol HistoryStore: Sendable {
  func append(_ readings: [SourceReading]) throws          // idempotent on (provider, fileKey, window, source, observedAt)
  func appendCounterMarks(_ marks: [CounterMark]) throws
  func saveLastSnapshot(_ s: SourceSnapshot) throws        // accounts, routing, unclassified; one per source
  func lastSnapshots() throws -> [SourceSnapshot]
  func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws -> [SourceReading]
  func latestReadings() throws -> [SourceReading]          // newest per (provider, fileKey, window, source)
  func counterMarks(since: Date) throws -> [CounterMark]
  func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int)   // assigns on first sight
  func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date?
  func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws   // from the last history response
  func forkProviderStates() throws -> [Provider: ForkProviderState]
  func recordGap(from: Date, to: Date) throws              // app asleep or not running
  func gaps(since: Date) throws -> [DateInterval]
  func prune(olderThan: Date) throws
}
struct CounterMark { let fileKey: String; let at: Date; let value: Int }

// Ledger (T4). T8 calls apply for every source snapshot and for fork `current`.
// Readings whose fileKey isn't in the latest credential list are kept in the store
// but ignored until a credential with that fileKey appears.
//   init(store: HistoryStore, settings: PoolSettings)   // store for alias(for:) and restore
//   func updateSettings(_ settings: PoolSettings)        // alias list changes take effect at once
//   func apply(_ s: SourceSnapshot)
//   func apply(readings: [SourceReading])
//   func restore() throws                                // last snapshots + latestReadings + counter marks

// Ledger -> pool engine and forecast
protocol LedgerView: Sendable {
  var accounts: [MergedAccount] { get }   // deduplicated by AccountID, with stable alias
  var routing: [SourceKind: RoutingConfig] { get }
  func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading?
  // plan.md Pool rule 3: true only with proof that this window was unused since resetAt
  func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool
  func unclassified(_ id: AccountID) -> [UnclassifiedReading]
}
// Pool engine (T3): PoolEngine.dashboard(ledger: LedgerView, settings: PoolSettings,
//   sources: [SourceKind: SourceStatus], now: Date) -> DashboardModel
// A provider whose source is .notConfigured gets no row.
struct CredentialRoute { let fileKey: String; let priority: Int; let weight: Int
                         let enabled: Bool; let unavailable: [Unavailability] }
struct MergedAccount { let id: AccountID; let alias: String; let email: String?
                       let enabled: Bool; let unavailable: [Unavailability]
                       let credentials: [CredentialRoute]   // routing is per credential file
                       let colorIndex: Int }

// Pool engine -> UI. The UI renders only this.
struct PercentRange: Equatable { let lower: Double; let upper: Double }   // equal when exact
struct GaugeBar: Equatable { let alias: String; let colorIndex: Int
                             let remaining: Double; let greyed: Bool }
struct AccountDetail: Equatable {       // hover
  let alias: String; let email: String?; let remaining: Double?
  let previous: (value: Double, observedAt: Date)?   // old value when now unknown
  let resetsAt: Date?; let observedAt: Date?; let stale: Bool
  let usable: Bool; let blockedReason: String?
}
struct WindowGauge: Equatable {
  let window: WindowKind; let known: Int; let total: Int
  let quota: PercentRange?; let usable: PercentRange?   // nil when total == 0
  let bars: [GaugeBar]                  // known accounts only, fullest first
  let nextRefill: (at: Date, poolGain: Double)?        // 5-hour only
  let allFull: Bool                     // at least one enabled account, and every enabled one at 100 and usable:
                                        // drives "reset in 5h"
  let pace: Double?                     // weekly only, expected remaining share 0...1
  let accounts: [AccountDetail]
}
struct ProviderRow: Equatable { let provider: Provider
  let fiveHour: WindowGauge?; let weekly: WindowGauge?; let monthly: WindowGauge?
  let unclassified: [UnclassifiedDetail] // hover only: alias + UnclassifiedReading fields
  let forecast: ForecastSummary? }      // nil until T11
struct UnclassifiedDetail: Equatable { let alias: String; let lengthSeconds: Int?
  let usedPercent: Double; let resetsAt: Date?; let observedAt: Date }
enum LockoutForecast: Equatable { case safe, lockout(from: Date, to: Date),
                                  withheld(reason: String), insufficientData }
struct ForecastSummary: Equatable { let poolBurnPerHour: Double?; let lockout: LockoutForecast
  let weeklyRunOut: Date?; let weeklyResets: Date? }
enum SourceStatus: Equatable { case ok(at: Date), authStopped(SourceError), failing(SourceError, since: Date), notConfigured }
struct DashboardModel: Equatable { let generatedAt: Date; let rows: [ProviderRow]
                                   let sources: [SourceKind: SourceStatus] }
```

Decisions inside the contracts:

- Dedupe merge (T4): accounts with the same `AccountID` merge. `enabled` if any file
  is enabled. Counter marks stay per credential file: a reset proof needs the same
  set of files before and after the reset, each with an unchanged counter, so use
  through any file, or a restart hidden by another file's rise, breaks it. Each
  window keeps the newest reading. The account's `unavailable` is empty when any
  enabled credential is available; otherwise it lists the reasons. The identity alias
  list in Settings (`[fileKey: canonical identity]`) is applied before the merge, at
  read time, so adding an alias later re-attaches readings already stored.
- Alias and color: assigned on first sight in a stable order (`claude-1`, ...) and
  stored in SQLite so they survive restarts. A color belongs to the account, so
  crossings swap positions, not colors.
- UI technology: the status item draws an `NSImage` (logos as template images plus
  text) on the `NSStatusItem` button. The dropdown is an `NSPopover` hosting SwiftUI,
  which gives hover on bars cheaply.
- Deployment target macOS 14. Bundle id `ca.lals.usage-monitor`, `LSUIElement = YES`,
  ad-hoc signed.

## Worked examples

These come from plan.md's rules, not from code. Tests use them as written.

| ID | Input | Expected |
|---|---|---|
| E1 | 5-hour remaining 70 and 53, third account unknown | quota 41-74% (123/3 and 223/3), "2 of 3 known", two bars |
| E2 | A 80 usable, B 50 blocked by weekly, C 35 usable | quota 55%, usable 38% (115/3), B greyed, dropdown shows both numbers |
| E3 | A 20 (resets 14:10), B 60 (resets 15:30), C 100, all usable | next refill 14:10, +27% of pool (80/3) |
| E3b | E3, but A is weekly-blocked until 16:00 | next refill 15:30, +13% (40/3); A's 14:10 reset isn't a refill |
| E4 | All 5-hour windows at 100, all accounts usable | `allFull`, row says "reset in 5h", no `nextRefill` |
| E4b | All at 100 at 13:00, B cooling down until 13:40 | not `allFull`; usable 67% (200/3); next refill 13:40, +33%; "reset in 40m" |
| E4c | E4's readings (all at 100), but every account disabled | not `allFull`; no quota, no countdown |
| E5 | A used 40, resets 12:00. Counters: 1500 at 11:50, then 1500 at 12:05 | at 12:05 A counts 100% left |
| E5b | Same, second listing shows 1502 | A unknown, hover shows previous 60% with its age |
| E5c | Same, second listing shows 20 (cliproxy restarted) | A unknown |
| E5d | A has two files: 100 and 10 at 11:50, then 0 and 110 at 12:05 (sum unchanged) | A unknown: the first file dropped |
| E5e | Same as E5, but a second file for A first appears at 12:05 | A unknown: the file set changed |
| E6 | Claude header utilization `0.53`, then `1.2`; reset `1764000000` | used 53, then 100; reset 2025-11-24T16:00:00Z |
| E7 | Snapshot 1: 5h 30%, 7d 10%. Snapshot 2: 7d 12% only | 5h stays 30% with snapshot 1's time; 7d is 12% |
| E8 | Codex primary window minutes 10080, no secondary; another reading with no length | weekly; the second one is in `ProviderRow.unclassified` (hover only), even when that account has no bar |
| E9 | ocgo account with no `polled_at`, headroom 100, percent 0 | unknown, not 100% |
| E10 | ocgo `forced_account: team-b`; team-b has a future `cooldown_until` but windows OK | team-a unusable (`notForcedAccount`), team-b usable |
| E11 | Weekly: account resets in 3.5 days, second counted as reset | pace marker at 75%. A known account with usage and no reset hides the marker |
| E12 | Used 10 at 12:00, 13 at 12:15, 16 at 12:30, same reset | burn 12%/h. Add 2 at 12:45 with a new reset: that interval is skipped |
| E13 | Credential list returns 401 | no further cliproxy request in 10 simulated minutes; ocgo keeps polling; no fork history request either; requests resume after a successful `test` of the saved config or `configChanged(.cliproxy)` |
| E14 | `claude-1a2b3c4d-x@example.com.json` twice (two files), plus legacy `claude-x@example.com.json` | two accounts; one once the alias list maps the legacy file to `1a2b3c4d` |
| E15 | Fork poller reset `0001-01-01T00:00:00Z` | `resetsAt == nil` |
| E16 | ocgo poll at 11:50: rolling 60% and weekly 30% used, both reset at 12:00. Poll at 12:02: rolling `ok` at 5%; weekly `status: "error"` with `percent: 0` and next week's `resets_at` | rolling 95% left (fresh reading); weekly unknown, hover shows 70% from 11:50 |

## Phase 0: owned by the user (or a host on NetBird)

None of these can run from lals-mini today. The code tasks below don't wait for them
except where marked.

| ID | Outcome | Blocks |
|---|---|---|
| P0.1 | Public ingress blocks `/v0/management/*` and `/v8/management/*` (checked from outside NetBird: the ingress itself rejects both, and cliproxy's log shows no request for those paths; any 401 or 403 from cliproxy fails the check). Then `allow-remote: true`. | Any live cliproxy call: P0.3, T10 |
| P0.2 | Fork source read on thearch: `quota.signals` value type, counter semantics, 403 message texts, `quota/history` JSON, listing fields. Notes go into plan.md. | T6 acceptance, `SourceError` mapping |
| P0.3 | Run `scripts/capture-fixtures.sh` (T2) once against both proxies; commit the sanitized output to `Fixtures/live/`. Fill in `EXPECTED.md` by hand: the capture time as the "as of" time, then per provider and window, the pooled % worked out from the fixture values at that time. | T6, T7 acceptance; T10 fixture replay |
| P0.4 | Record routing strategy, weights, priorities, session affinity, `forced_account`; duplicate Claude credential pairs; whether Go accounts are distinct workspaces. | Default alias list; T11b scope (affinity on means no lockout forecast) |
| P0.5 | Find why T3 showed no usage (replay `auth-files` and `api-call` by hand). | Only the active-calls path (T12), which is out of the first build |

## Tasks

### T1. Tracer bullet: ocgo to the menubar

Outcome: `make app && open build/UsageMonitor.app` shows the Go logo and "48%" in the
menubar, read from a synthetic `/_ocgo/status` fixture (or the live proxy when
`--ocgo-url` and a Keychain token exist). It tests the uncertain parts end to end:
the SwiftPM-to-.app bundle, template logos in the status item, Keychain from an
ad-hoc-signed app, `HTTPTransport`, and whether the contract types fit one real
source.

- Components: `Package.swift`, `Makefile`, `scripts/bundle.sh`, `Contracts/`, a
  minimal `OcgoSource` (5-hour `rolling` only), a minimal pool mean (Pool rule 1
  only), a bare status item.
- Acceptance:
  - `make test` passes; `make app` builds a bundle with no Dock icon.
  - The fixture's three accounts at used 52, 40 and 64 give "48%"
    (mean remaining (48+60+36)/3).
  - The token written by a debug menu entry is read back after quitting and
    relaunching. Then rebuild and relaunch, and record whether macOS prompts. If it
    does, write down the fix (a local self-signed signing identity) for T9c.
  - The contract types compile, including `HistoryStore`, `ForkHistorySource`,
    `LedgerView`, `PollControl`, the settings types and `ForecastSummary`, and the
    integrator has reviewed them. After that they are frozen.
- Depends on: nothing. Blocks: every other code task.
- Verification: `make test`; launch and look at the menubar in light and dark
  appearance; the Keychain relaunch check above.

### T2. Fixture capture script

Outcome: `scripts/capture-fixtures.sh` makes exactly one request per endpoint
(credential list, `quota/history?range=24h`, routing strategy, config, `/_ocgo/status`),
stops at the first 401 or 403 without trying anything else, and writes sanitized JSON.
From the config response it keeps only the `routing` object; the rest (API keys,
secrets, upstream URLs) is never written.
Sanitizing replaces emails with `user-N@example.com`, using one email map for every
file in a run so joins across endpoints still match, and keeps the 8-hex hash in
credential names, strips every token-like field (`access_token`, `refresh_token`,
`id_token` except the derived `chatgpt_account_id`, which gets a stable fake), and
keeps header names and casing.

- Depends on: nothing; runs in parallel with T1. Blocks: P0.3.
- Acceptance: a sanitizer test over a synthetic payload that contains every field
  above; the output has no `@` other than `@example.com`, no `eyJ` JWT prefix, and
  the same hash for two files of one subscription. An opaque key placed in the
  synthetic config (`sk-test-opaque-1234`, not JWT-shaped) is absent from every
  output file (`grep -r` finds nothing), while the synthetic `routing` object
  (strategy `fill-first`, session affinity on) comes through unchanged. A fake
  server that answers 401 gets exactly one request. Two accounts listed in opposite
  order in the credential list and in `quota/history` get the same sanitized ids in
  both output files.
- Verification: run the script against a local `python3 -m http.server` stub serving
  the synthetic payloads, and against a stub that answers 401.

### T3. Pool engine (Pool rules 1 to 6, weekly pace)

Outcome: `PoolEngine.dashboard(ledger: LedgerView, settings: PoolSettings,
sources: [SourceKind: SourceStatus], now: Date) -> DashboardModel`, a pure function.

- Acceptance: E1 to E4c (E4c: `allFull == false`, `quota == nil`,
  `nextRefill == nil`), E11, and E8's dashboard half through a fake `LedgerView`.
  E5 to E5e as dashboard values, with the fake's `resetProven` set to each
  example's answer: true gives 100% left, false gives unknown with the previous
  value and its age in hover. `sources` with `.ocgo: .notConfigured` gives no Go
  row even when the fake `LedgerView` still holds Go accounts, and `sources` comes through unchanged in `DashboardModel.sources`. Staleness flag at the
  threshold (29 min fresh, 31 min stale with the default); disabled accounts left
  out of `total`; Go monthly blocking the 5-hour usable share like weekly.
- Depends on: T1. Parallel with T4, T5, T7, T9.
- Verification: `make test`. Expected values come from the worked examples only.

### T4. Ledger and deduplication

Outcome: the `Ledger` from the contracts (`apply` for snapshots and for fork
`current` readings, `restore`), implementing `LedgerView`: last reading per account
and window, a missing window doesn't erase an earlier one, readings resolved from
`fileKey` to account at read time, merging by identity with the alias list, counter
marks and `resetProven`.

- Acceptance: E5 to E5e (through `resetProven`), E7, E14, E16. Reset proof is per
  account and window: the ocgo proof is a fresh `ok` reading of that window, never
  the account's `polledAt` alone. Restore: after applying a cliproxy and an ocgo
  snapshot (including a never-polled Go account and a `forced_account`) and both
  E7 snapshots, a ledger
  restored from the same store with no new snapshot gives the same `accounts`,
  `routing`, `latest`, `unclassified` and `resetProven` answers; E7's 5-hour 30%
  keeps snapshot 1's timestamp. Credential merge: snapshots with two enabled files
  for A (one `upstreamUnavailable`) and one available file for B give A usable, the
  flag on the right `CredentialRoute`, and B unchanged; T11b's 1/2 case runs on
  these merged routes. Fork join: a fork `current` reading for a Codex `fileKey`
  resolves to the account whose credential carries that `chatgpt_account_id`; one
  for a `fileKey` not in the credential list is ignored. Alias: E14's legacy file
  with stored readings, restored after the alias is added, shows those readings on
  account `1a2b3c4d`; the same alias passed to `updateSettings` on a running ledger
  merges the two accounts without a restore.
- Depends on: T1 (the `HistoryStore` protocol is in the T1 contracts; a fake until
  T5 lands).
- Verification: `make test`.

### T5. SQLite history store

Outcome: a SQLite implementation of `HistoryStore` with tables for readings, counter
marks (per credential file), aliases, the last snapshot per source (accounts,
routing, unclassified readings, as JSON), gaps, and meta (schema version, fork
provider states). It writes readings and marks,
answers queries by time range, prunes rows older than 30 days on open and daily, and
has idempotent inserts keyed by `(provider, fileKey, window, source, observedAt)`.

- Acceptance: data survives closing and reopening the database file; a row 31 days
  old is gone after prune and a 29-day row stays; inserting the same fork history
  twice gives one row; a passive and a fork reading with the same file, window
  and `observedAt` both survive reopening; aliases, the last snapshots, gaps and
  fork provider states survive reopening.
- Depends on: T1. Parallel with T3, T4.
- Verification: `make test` against a temporary file database.

### T6. cliproxy source

Outcome: `CliproxySource: UsageSource` and `ForkHistorySource`. It parses the credential
list (identity, enabled, unavailable, counters, routing fields), passive signals for
Claude and Codex (plan.md "Reading passive signals"), the routing strategy and config,
and the fork's `quota/history` in one response for all providers (current readings
from `accounts[].reading.windows`, history deduplicated with the `status: "ok"`
filter, `"anthropic"` read as `"claude"`, and `paused` per provider). It maps HTTP failures to `SourceError` and strips `/management.html`
from the URL. Its requests run one after another, credential list first; the first
auth error returns at once.

- Acceptance: E6, E8, E15; a 401 or 403 on the credential list gives exactly one HTTP
  request (no routing or config call); case-insensitive header matching; a missing reset or
  epoch 0 gives `nil`; Codex reset from `observed_at` + `-Reset-After-Seconds`;
  `weight <= 0` under weighted-round-robin gives `outOfRotation`; a history payload
  where Codex accounts are `paused` gives `providers[.codex] == .paused`, and one
  with an active provider but no samples in range gives `.served` with no history;
  parses every file
  in `Fixtures/live/`.
- Depends on: T1 to start (on synthetic payloads shaped like plan.md). Acceptance
  waits for P0.2 and P0.3; if the live payloads differ, the parser follows them and
  plan.md gets corrected.
- Verification: `make test`; the live-fixture parse tests fail until P0.3 lands and
  are marked skipped with a reason, not deleted.

### T7. ocgo source, complete

Outcome: extends T1's `OcgoSource` to every rule in plan.md "Reading the status": all
three windows, never polled means unknown, `poll_error` keeps the last good reading,
`status != "ok"` is ignored, availability reasons, `forced_account`.

- Acceptance: E9, E10; a window past `resets_at` with `polled_at` before it isn't
  reset; parses the live ocgo fixture once P0.3 lands.
- Depends on: T1. Parallel.
- Verification: `make test`.

### T8. Poll coordinator

Outcome: an actor that every 60 s polls the credential list, ocgo status, and the
fork's `quota/history` (one request for all providers), feeds the ledger and store,
and publishes a `DashboardModel`. Each tick runs the cliproxy source, then the fork
history request, one after another; an auth error from the first skips the second.
It latches on auth errors (401, or 403 for remote disabled or banned) and stops all
cliproxy requests. The latch clears only through `PollControl`: `configChanged` after
Settings saves a changed URL or secret, or `test` with the saved configuration when
its single request succeeds. `poolSettingsChanged` passes new settings to the ledger
and to every later `PoolEngine.dashboard` call, then republishes, without touching
the latch. Settings calls these two and never a source directly. History `range` is the time since the oldest of the
newest fork-poller observations of the served providers
(`lastObservation(p, source: .forkPoller)`; passive readings don't count), clamped to
1h-720h, so start and wake catch up. "Served" is the provider state from the last
history response, saved with `saveForkProviderStates`, so the first request after
launch uses it too. With no stored fork observation for any served provider (first
launch), the range is 24h. A provider the fork
reports `paused`, or every provider when the route answers 404, uses the app's own
readings. T8 records a gap in the store for each sleep-to-wake span
(`NSWorkspace` notifications, passed in as an async sequence) and for the span from
the last stored poll to launch.

- Acceptance: E13 through `test(.cliproxy, saved)` (success resumes polling) and
  through `configChanged(.cliproxy)`; on the 401 tick the fork history source gets no
  call; a Test that gets a 401 sends one request and polling stays latched; a
  successful Test of an unsaved key leaves polling latched; `poolSettingsChanged`
  while latched, lowering `staleAfter` from 30 to 10 min, republishes a model where a
  15-minute-old reading is now stale, and sends no cliproxy request; a 403 latches the same
  way; a failing ocgo doesn't stop cliproxy. With a fake clock and fake sources,
  5 simulated minutes send exactly 5 credential-list
  requests and 5 `quota/history` requests; a 404 history route or a `paused` Codex
  switches that provider to local readings; a simulated sleep from 13:00 to 14:00
  stores that gap. After a sleep from 10:00 to 13:00 (last fork observation 09:59),
  where the first credential list after wake brings fresh passive readings, the
  history request asks for `range` = 3h01m. Relaunch tests: a first coordinator
  receives a fake history response (fork observations at 09:59 for Claude and 09:50
  for Codex, both served) and is discarded; a fresh coordinator on the same store
  at 13:00, with fresh passive readings stored first, sends `range` = 3h10m as its
  first request. Paused variant: the first coordinator processes that served
  response, then a second one that marks Codex paused and carries no Codex history;
  the store still holds Codex's 09:50 observation before the relaunch, and the fresh
  coordinator's first request is `range` = 3h01m (Claude only). First launch on an
  empty store: 24h.
- Depends on: T4, T5, and the `UsageSource` and `ForkHistorySource` contracts (fakes
  until T6 and T7 land).
- Verification: `make test` with fake sources that record every call.

### T9a. Status item: Normal and Compact

Outcome: a status item controller driven by `DashboardModel` and the menubar style
setting. Normal shows logo + usable 5-hour % per provider (a range shows as
"41-74%"). Compact shows the three-spoke glyph; a click expands it for 3 s; a click
while expanded opens the dropdown.

- Acceptance: a pure layout function puts a 14 px glyph, 3 px gap and 10 px between
  providers (unit-tested on widths); the expand state machine, with an injected
  timer, goes collapsed → expanded → collapsed after 3 s, and expanded + click →
  dropdown; a provider whose source isn't configured doesn't appear.
- Depends on: T1 (contract). Uses fixture `DashboardModel` values.
- Verification: `make test`; by hand in light and dark menubars.

### T9b. Dropdown with the overlap line

Outcome: a popover with one row per provider: the 5-hour overlap line (E), the pooled
number, "reset in …" bottom right, "usable X%, quota Y%" when they differ, "N of M
known", the weekly line with its pace marker, Go monthly, hover detail, freshness and
stale marks, and auth or error state per source.

- Acceptance: a pure function `overlapRects(bars:width:)` gives, for remaining 80,
  50, 35 at width 200, rects 0-160, 0-100, 0-70, drawn in that order (emptiest on
  top), square ends; greyed bars use the grey style; the countdown text comes from
  `nextRefill` or `allFull`; renders the E1 to E4 models to PNGs
  (`bitmapImageRepForCachingDisplay`) for the user to compare with
  `docs/mockups/gauges-overlap.html`; with E8's no-bar case, the unclassified
  reading is reachable from the provider row's hover.
- Depends on: T1. Parallel with T9a and T9c.
- Verification: `make test`; the user reviews the PNGs (style rules in plan.md
  "Gauge design").

### T9c. Setup screen and Keychain

Outcome: a settings window shown on first launch: cliproxy URL and management key,
optional ocgo URL and token, menubar style, stale threshold, identity alias list. A
Test button per source calls `PollControl.test` with the values in the form (one
request, never retried) and reports the result in words, one message per
`SourceError` case. Saving calls `configChanged(kind)` only for a source whose URL
or secret changed, and `poolSettingsChanged` when the stale threshold or alias list
changed. Secrets live in the Keychain, everything
else in `UserDefaults`.

- Acceptance: each `SourceError` case maps to its sentence (unit test); Test and Save
  call `PollControl` (checked with a fake): `test` receives the form's
  `SourceConfig`; saving an alias or stale-threshold change calls
  `poolSettingsChanged` and no `configChanged`; saving only a menubar style calls
  neither; saving a changed cliproxy URL or key calls `configChanged(.cliproxy)`; with an empty ocgo URL the
  Go row is hidden.
- Depends on: T1 (and its Keychain finding).
- Verification: `make test`; by hand: save, quit, relaunch, values still present.

### T10. Integration: Phase 2 done

Owner: integrator. Wires sources, coordinator, engine and UI in `Wiring.swift`, then
checks the combined behavior.

- Fixture replay test: the coordinator with a transport serving `Fixtures/live/` and
  a `NowProvider` fixed at `EXPECTED.md`'s "as of" time produces a `DashboardModel`
  whose pooled values equal `EXPECTED.md`.
- Pipeline test for E16: the two raw synthetic `/_ocgo/status` responses (11:50,
  then 12:02) through T7, T4 and T3 give Go rolling 95% left, weekly unknown, and
  70% from 11:50 in the weekly hover.
- Live run on the Mac against both proxies (needs P0.1 and P0.3): menubar % equals a
  hand calculation from a capture taken in the same minute. If openusage is
  installed, its unified Claude row is a second check, allowing for its "earliest
  reset" rule.
- The manual checks from plan.md Phase 2: Compact expands for 3 s and a second click
  opens the dropdown; key and token survive a relaunch; without ocgo the Go row is
  hidden. Plus: a wrong key gives one 401 and then silence (watch the proxy log or a
  local stub).
- Depends on: T3 to T9c, P0.1, P0.3.

### T11. Forecast (Phase 3)

Four outcomes, all pure functions over history from the store (queried by each
account's credential `fileKey`s) and the current `LedgerView`. T11a to T11c can start any time after T1. T11d waits for T10.

- T11a burn rate: per account and window, EWMA over the last 30-60 min with the
  same-window rule (reset agreement within 60 s, or earlier reading at 0% with an
  unset reset). It takes the history source chosen per provider (fork or local,
  from T8). An account's readings from several credential files are merged into one
  series with one reading per `observedAt`: the highest `usedPercent` wins, then the
  lowest `fileKey`. For local history only, an interval
  that overlaps a stored gap is skipped, and the rate needs readings at 3 distinct
  times after the last gap before it reports. Acceptance: E12; a reset in the middle drops that interval and its time;
  with local history, three readings before a gap and one after give no rate;
  readings at 12:00, 12:05, 12:10 (10, 11, 12% used), a gap to 12:30, then 30, 31,
  32% at 12:30, 12:35, 12:40 give 12%/h (counting the gap would give 33%/h); a
  two-file account with both files read at 12:30 and 12:35 after a gap (four rows,
  two times) gives no rate, and the same account read at 12:30, 12:35 and 12:40,
  file `a` at 30, 30, 30% and file `b` at 30, 31, 32% (six rows, three times), gives
  12%/h (lowest-wins or `fileKey`-first would give 0%/h); the same 20-minute sleep with fork
  history holding four samples inside it gives a rate from all of them.
- T11b 5-hour simulation: per minute over 5 hours, demand split by the configured
  routing (`LedgerView.routing`: strategy, session affinity, `forced_account`) over
  the enabled credential routes (weights, priority tiers), with one quota balance
  per subscription, resets applied, a
  new window on first use, lockout minutes flagged. Acceptance: a three-account case
  worked out by hand per strategy (round-robin, weighted, fill-first,
  most-headroom); A with two equal-weight credentials and B with one, under
  round-robin, puts 2/3 of demand on A, and 1/2 when one of A's credentials is
  unavailable; session affinity on gives `.withheld`.
- T11c weekly run-out: linear per account to its weekly reset. Acceptance: used 50%
  at 10%/day with reset in 6 days gives a run-out in 5 days, shown as "runs out
  <day> <time>, resets <day> <time>".
- T11d text in the dropdown and the backtest from plan.md Phase 3: a lockout and its
  recovery reproduced within 15 min on real history, or on a labeled fixture if the
  history has no lockout; no lockout predicted where the usable pool stayed above 0.

### T12. Active usage calls (deferred)

Off by default and not built in the first pass. Blocked by P0.5 and by `api-call`
fixtures. Allowed only when the fork's poller isn't running. Rules are in plan.md
Architecture.

## Order and parallel work

```
T1 ─┬─ T3 ───────────────┐
    ├─ T4 ─┐             │
    ├─ T5 ─┴─ T8 ────────┤
    ├─ T6 (synthetic) ···┼─ T10 ── T11d
    ├─ T7 ───────────────┤
    ├─ T9a, T9b, T9c ────┘
    └─ T11a, T11b, T11c (any time; low priority)
T2 ─ P0.3 ─ T6/T7 acceptance, T10
P0.1 ─ P0.3, T10 live      P0.2 ─ T6 acceptance      P0.4 ─ T11b scope
```

- Wave 1: T1, with T2 alongside. Nothing else starts until T1's contract review,
  because every task builds on those types.
- Wave 2, up to four at once: T3, T4, T5, T9b; then T7, T9a, T9c, T6. They touch
  separate folders and only read `Contracts/`.
- Wave 3: T8 once T4 and T5 are merged; T6 is finished when P0.2 and P0.3 arrive.
- Wave 4: T10 by the integrator. Wave 5: T11.

Integration rules:

- Each task lands as its own commit on `main` after `make test` passes on the
  combined tree, merged one at a time by the integrator. With worktrees, each task
  rebases on the latest `main` before it's merged.
- A contract change after T1 is the integrator's call. They update `Contracts/`,
  fix callers in the same commit, and tell any task still running.
- `make test` runs the whole suite (core and app tests) on every merge; T10's fixture
  replay test then guards the whole pipeline.
