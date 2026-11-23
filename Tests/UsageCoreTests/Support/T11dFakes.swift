import Foundation
import UsageCore

/// Forwards to a real store; `readings` and `gaps` (what the forecast reads) throw
/// while `failing` is set.
final class T11dFailingReadsStore: HistoryStore, @unchecked Sendable {
    struct Injected: Error {}
    let base: any HistoryStore
    let failing = T8Box(false)

    init(_ base: any HistoryStore) { self.base = base }

    func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws -> [SourceReading] {
        if failing.get { throw Injected() }
        return try base.readings(fileKeys: fileKeys, w, from: from, to: to)
    }
    func gaps(since: Date) throws -> [DateInterval] {
        if failing.get { throw Injected() }
        return try base.gaps(since: since)
    }

    func append(_ readings: [SourceReading]) throws { try base.append(readings) }
    func appendCounterMarks(_ marks: [CounterMark]) throws { try base.appendCounterMarks(marks) }
    func saveLastSnapshot(_ s: SourceSnapshot) throws { try base.saveLastSnapshot(s) }
    func lastSnapshots() throws -> [SourceSnapshot] { try base.lastSnapshots() }
    func latestReadings() throws -> [SourceReading] { try base.latestReadings() }
    func counterMarks(since: Date) throws -> [CounterMark] { try base.counterMarks(since: since) }
    func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int) { try base.alias(for: id) }
    func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date? {
        try base.lastObservation(p, source: source)
    }
    func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws { try base.saveForkProviderStates(s) }
    func forkProviderStates() throws -> [Provider: ForkProviderState] { try base.forkProviderStates() }
    func recordGap(from: Date, to: Date) throws { try base.recordGap(from: from, to: to) }
    func prune(olderThan: Date) throws { try base.prune(olderThan: olderThan) }
}

/// A capture folder transport whose answers for some paths are replaced.
struct T11dOverridingTransport: HTTPTransport {
    let base: T10FolderTransport
    let overrides: [String: Data]

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = r.url, let body = overrides[url.path] else { return try await base.send(r) }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
