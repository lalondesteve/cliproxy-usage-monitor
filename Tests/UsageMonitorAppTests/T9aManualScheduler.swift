import Foundation
@testable import UsageMonitorApp

/// A virtual clock for `CompactExpander`: timers fire only when the test advances time.
@MainActor
final class T9aManualScheduler: OneShotScheduling {
    private final class Token: OneShotToken {
        let at: TimeInterval
        let fire: @MainActor () -> Void
        var cancelled = false
        init(at: TimeInterval, fire: @escaping @MainActor () -> Void) {
            self.at = at
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private var tokens: [Token] = []

    var pendingCount: Int { tokens.filter { !$0.cancelled }.count }

    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any OneShotToken {
        let token = Token(at: now + seconds, fire: fire)
        tokens.append(token)
        return token
    }

    /// Moves the clock forward, firing due timers in order.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = tokens.filter({ !$0.cancelled && $0.at <= end }).min(by: { $0.at < $1.at }) {
            now = next.at
            tokens.removeAll { $0 === next }
            next.fire()
        }
        now = end
        tokens.removeAll { $0.cancelled }
    }
}
