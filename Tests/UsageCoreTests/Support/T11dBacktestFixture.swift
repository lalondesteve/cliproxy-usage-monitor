import Foundation
import UsageCore

/// One provider's scenario from Fixtures/synthetic/T11d (see its README.md): the
/// readings in a fresh SQLite store, the accounts, the routing and the labels.
struct T11dScenario {
    struct Interval: Decodable {
        let from: Date
        let to: Date
        var interval: DateInterval { DateInterval(start: from, end: to) }
    }

    private struct File: Decodable {
        struct Routing: Decodable {
            let source: SourceKind
            let strategy: RoutingConfig.Strategy
            let sessionAffinity: Bool
        }
        struct Account: Decodable { let identity: String; let alias: String; let fileKey: String }
        struct Replay: Decodable { let from: Date; let to: Date; let stepMinutes: Int }
        struct Labels: Decodable { let lockout: Interval; let poolAboveZero: [Interval] }
        let readings: String
        let history: String
        let routing: Routing
        let accounts: [Account]
        let replay: Replay
        let labels: Labels
    }

    static let folder = "synthetic/T11d"

    let provider: Provider
    let history: ForecastHistory
    let accounts: [MergedAccount]
    let routing: [SourceKind: RoutingConfig]
    let readings: [SourceReading]
    let times: [Date]
    let lockout: DateInterval
    let poolAboveZero: [DateInterval]
    let store: SQLiteHistoryStore
    private let database: T5TempDatabase

    /// `sessionAffinity` overrides the scenario's routing.
    init(_ provider: Provider, sessionAffinity: Bool? = nil) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = try decoder.decode([String: File].self,
                                     from: try Fixtures.data("\(Self.folder)/scenarios.json"))
        guard let file = all[provider.rawValue] else { throw FixtureError("no scenario for \(provider)") }
        guard let history = ForecastHistory(rawValue: file.history) else {
            throw FixtureError("unknown history \(file.history)")
        }
        self.provider = provider
        self.history = history
        accounts = file.accounts.enumerated().map { i, a in
            MergedAccount(id: AccountID(provider: provider, identity: a.identity), alias: a.alias,
                          email: nil, enabled: true, unavailable: [],
                          credentials: [CredentialRoute(fileKey: a.fileKey, priority: 0, weight: 1,
                                                        enabled: true, unavailable: [])],
                          colorIndex: i)
        }
        routing = [file.routing.source: RoutingConfig(
            strategy: file.routing.strategy,
            sessionAffinity: sessionAffinity ?? file.routing.sessionAffinity, forcedAccount: nil)]
        readings = try Self.parse(provider, csv: try Fixtures.data("\(Self.folder)/\(file.readings)"))
        times = Backtest.times(from: file.replay.from, to: file.replay.to,
                               step: TimeInterval(file.replay.stepMinutes * 60))
        lockout = file.labels.lockout.interval
        poolAboveZero = file.labels.poolAboveZero.map(\.interval)
        database = T5TempDatabase()
        // No pruning: the fixture's dates are fixed and may be older than 30 days.
        store = try SQLiteHistoryStore(path: database.path, retention: nil)
        try store.append(readings)
    }

    func run() throws -> Backtest.Report {
        try Backtest.run(provider, accounts: accounts, routing: routing, store: store,
                         history: history, at: times)
    }

    static func parse(_ provider: Provider, csv: Data) throws -> [SourceReading] {
        let lines = String(decoding: csv, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.first == "observed_at,file_key,window,used_percent,resets_at,source" else {
            throw FixtureError("unexpected CSV header")
        }
        return try lines.dropFirst().map { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let window = WindowKind(rawValue: f[2]), let used = Double(f[3]),
                  let source = ReadingSource(rawValue: f[5]) else {
                throw FixtureError("bad CSV line: \(line)")
            }
            return SourceReading(provider: provider, fileKey: f[1], window: window, usedPercent: used,
                                 resetsAt: f[4].isEmpty ? nil : date(f[4]), observedAt: date(f[0]),
                                 source: source)
        }
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

/// 2026-11-22 at `hh:mm` UTC.
func t11d(_ hhmm: String) -> Date { date("2026-11-22T\(hhmm):00Z") }

/// A short hand-written history in a fresh store (no pruning), with stored gaps.
struct T11dHandHistory {
    let store: SQLiteHistoryStore
    private let database: T5TempDatabase

    init(_ readings: [SourceReading], gaps: [DateInterval] = []) throws {
        database = T5TempDatabase()
        store = try SQLiteHistoryStore(path: database.path, retention: nil)
        try store.append(readings)
        for g in gaps { try store.recordGap(from: g.start, to: g.end) }
    }

    /// 5-hour readings every 5 minutes from `from` through `to`; the k-th (from 0) at
    /// `used(k)`.
    static func every5Minutes(_ provider: Provider, _ fileKey: String, _ source: ReadingSource,
                              from: String, to: String, resetsAt: String,
                              used: (Int) -> Double) -> [SourceReading] {
        Backtest.times(from: t11d(from), to: t11d(to), step: 300).enumerated().map { k, t in
            SourceReading(provider: provider, fileKey: fileKey, window: .fiveHour, usedPercent: used(k),
                          resetsAt: t11d(resetsAt), observedAt: t, source: source)
        }
    }

    static func account(_ provider: Provider, _ identity: String, _ fileKey: String,
                        weight: Int = 1, index: Int = 0) -> MergedAccount {
        MergedAccount(id: AccountID(provider: provider, identity: identity), alias: identity, email: nil,
                      enabled: true, unavailable: [],
                      credentials: [CredentialRoute(fileKey: fileKey, priority: 0, weight: weight,
                                                    enabled: true, unavailable: [])],
                      colorIndex: index)
    }
}
