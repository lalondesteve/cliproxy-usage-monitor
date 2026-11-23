import Foundation

/// Which history a provider's burn rate reads (plan.md "Forecast", last bullet). T8
/// decides it per provider and passes it in:
///
/// - `fork`: the fork's `quota/history` (`ReadingSource.forkPoller`), used for Claude and
///   Codex while the VM serves it and the provider isn't paused. The fork kept polling
///   while the Mac slept, so stored gaps don't apply.
/// - `local`: the app's own readings (passive signals, ocgo status, active calls). They
///   have holes while the Mac sleeps, so intervals that overlap a stored gap are skipped
///   and the rate waits for fresh readings after the last gap.
public enum ForecastHistory: String, CaseIterable, Equatable, Sendable {
    case fork, local

    /// Whether a stored reading belongs to this history.
    public func accepts(_ source: ReadingSource) -> Bool {
        switch self {
        case .fork: source == .forkPoller
        case .local: source != .forkPoller
        }
    }
}

/// One account's window now, after Pool rule 3: a window past its reset counts as reset
/// (100% left, next reset unknown) only with the ledger's proof; otherwise it is
/// unknown. Shared by the simulation and the weekly run-out.
struct ForecastWindow {
    /// 0...100; nil when unknown (no reading, or past its reset without proof).
    let remaining: Double?
    /// The next reset; nil when unset, unknown, or counted as reset.
    let resetsAt: Date?
    /// There is a reading for this window at all.
    let read: Bool

    init(_ ledger: any LedgerView, _ id: AccountID, _ w: WindowKind, now: Date) {
        guard let r = ledger.latest(id, w)?.reading else {
            remaining = nil; resetsAt = nil; read = false
            return
        }
        read = true
        if let reset = r.resetsAt, reset <= now {
            remaining = ledger.resetProven(id, w, resetAt: reset) ? 100 : nil
            resetsAt = nil
        } else {
            remaining = min(max(100 - r.usedPercent, 0), 100)
            resetsAt = r.resetsAt
        }
    }
}
