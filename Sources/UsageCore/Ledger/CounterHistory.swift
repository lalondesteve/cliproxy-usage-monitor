import Foundation

/// Per-file request counters across credential listings (plan.md Pool rule 3,
/// cliproxy proof). A listing is the set of `CounterMark`s that share one `at`.
///
/// Each file keeps runs: a run covers consecutive listings in which the file was
/// present with the same counter value. A listing without the file, or a different
/// value, ends the run. So "file f was present and unchanged at every listing from
/// t0 to t1" is one run with `from <= t0` and `to >= t1`.
struct CounterHistory: Sendable {
    struct Run: Equatable, Sendable {
        var from: Date
        var to: Date
        let value: Int
    }

    /// Runs older than this, measured from the newest listing, are dropped. The store
    /// keeps 30 days, so a restored ledger never holds more than this either.
    static let retention: TimeInterval = 31 * 24 * 3600

    private(set) var listings: [Date] = []
    private(set) var runs: [String: [Run]] = [:]

    var lastListing: Date? { listings.last }

    var fileKeys: Dictionary<String, [Run]>.Keys { runs.keys }

    /// The newest listing strictly before `date`.
    func lastListing(before date: Date) -> Date? {
        // Binary search: listings are sorted ascending.
        var lo = 0, hi = listings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if listings[mid] < date { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : listings[lo - 1]
    }

    /// Adds one listing. Listings must arrive in time order; one that isn't newer than
    /// the last is ignored (a re-applied snapshot, or a late one). An empty listing
    /// adds nothing, so live and restored ledgers agree (the store has no row for it).
    mutating func record(at: Date, marks: [String: Int]) {
        guard !marks.isEmpty else { return }
        if let last = listings.last, at <= last { return }
        let previous = listings.last
        listings.append(at)
        for (fileKey, value) in marks {
            if var fileRuns = runs[fileKey], let lastRun = fileRuns.last,
               lastRun.to == previous, lastRun.value == value {
                fileRuns[fileRuns.count - 1].to = at
                runs[fileKey] = fileRuns
            } else {
                runs[fileKey, default: []].append(Run(from: at, to: at, value: value))
            }
        }
        prune(before: at.addingTimeInterval(-Self.retention))
    }

    /// The file's run that ends at `listing`, if the file was in that listing.
    func run(_ fileKey: String, endingAt listing: Date) -> Run? {
        guard let last = runs[fileKey]?.last, last.to == listing else { return nil }
        return last
    }

    /// True when the file was in any listing within `from...to`.
    func present(_ fileKey: String, from: Date, to: Date) -> Bool {
        guard let fileRuns = runs[fileKey] else { return false }
        for run in fileRuns.reversed() {
            if run.to < from { return false }
            if run.from <= to { return true }
        }
        return false
    }

    private mutating func prune(before cutoff: Date) {
        if let first = listings.first, first < cutoff {
            listings.removeAll { $0 < cutoff }
        }
        for (fileKey, fileRuns) in runs where fileRuns.first.map({ $0.to < cutoff }) ?? false {
            let kept = fileRuns.filter { $0.to >= cutoff }
            runs[fileKey] = kept.isEmpty ? nil : kept
        }
    }
}
