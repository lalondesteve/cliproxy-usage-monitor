import Foundation

/// Persistence, used by T4 (restore), T8 (writes) and T11 (history). T5 implements.
/// T8 persists source output unchanged; nothing in the store depends on the alias list.
public protocol HistoryStore: Sendable {
    /// Idempotent on (provider, fileKey, window, source, observedAt).
    func append(_ readings: [SourceReading]) throws
    func appendCounterMarks(_ marks: [CounterMark]) throws
    /// Accounts, routing, unclassified; one per source.
    func saveLastSnapshot(_ s: SourceSnapshot) throws
    func lastSnapshots() throws -> [SourceSnapshot]
    func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws -> [SourceReading]
    /// Newest per (provider, fileKey, window, source).
    func latestReadings() throws -> [SourceReading]
    func counterMarks(since: Date) throws -> [CounterMark]
    /// Assigns on first sight.
    func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int)
    func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date?
    /// From the last history response.
    func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws
    func forkProviderStates() throws -> [Provider: ForkProviderState]
    /// App asleep or not running.
    func recordGap(from: Date, to: Date) throws
    func gaps(since: Date) throws -> [DateInterval]
    func prune(olderThan: Date) throws
}

/// A credential file's request counter (cliproxy success + failed) at a listing.
public struct CounterMark: Codable, Equatable, Hashable, Sendable {
    public let fileKey: String
    public let at: Date
    public let value: Int

    public init(fileKey: String, at: Date, value: Int) {
        self.fileKey = fileKey
        self.at = at
        self.value = value
    }
}
