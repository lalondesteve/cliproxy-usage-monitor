import Foundation

/// How the coordinator finds and builds its sources (T10 wires it to Settings and the
/// Keychain). The coordinator reads `savedConfig` at init and again in
/// `configChanged(kind)`, and builds a source for that configuration each time.
public struct PollSetup: Sendable {
    /// The saved configuration for a source, or nil when it isn't configured.
    public var savedConfig: @Sendable (SourceKind) -> SourceConfig?
    /// A source for `kind` that polls with `config`.
    public var makeSource: @Sendable (SourceKind, SourceConfig) -> any UsageSource
    /// The fork's `quota/history` client for a cliproxy configuration, or nil to never
    /// ask for fork history.
    public var makeForkSource: @Sendable (SourceConfig) -> (any ForkHistorySource)?

    public init(savedConfig: @escaping @Sendable (SourceKind) -> SourceConfig?,
                makeSource: @escaping @Sendable (SourceKind, SourceConfig) -> any UsageSource,
                makeForkSource: @escaping @Sendable (SourceConfig) -> (any ForkHistorySource)?) {
        self.savedConfig = savedConfig
        self.makeSource = makeSource
        self.makeForkSource = makeForkSource
    }
}

/// Waits between ticks. Tests pass one that moves a fake clock instead of sleeping.
public protocol PollScheduler: Sendable {
    /// Returns at or after `date`; returns at once when `date` has passed. Throws to
    /// stop the polling loop (cancellation).
    func sleep(until date: Date) async throws
}

/// Sleeps on the continuous clock, which keeps counting while the Mac sleeps, so the
/// first tick after a long sleep runs as soon as the Mac wakes.
public struct SystemPollScheduler: PollScheduler {
    public init() {}

    public func sleep(until date: Date) async throws {
        let delay = date.timeIntervalSinceNow
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay), clock: .continuous)
        } else {
            try Task.checkCancellation()
        }
    }
}

/// The Mac going to sleep and waking (`NSWorkspace.willSleepNotification` and
/// `didWakeNotification`, turned into an async sequence by the app), each stamped with
/// the time the app received the notification. The gap runs from one to the other.
public enum PowerEvent: Sendable, Equatable {
    case willSleep(at: Date)
    case didWake(at: Date)
}

/// Where T11 reads a provider's history from (plan.md "Forecast": history is chosen
/// per provider).
public enum HistoryOrigin: Sendable, Equatable {
    /// The fork's `quota/history`: served for this provider by the last response.
    case fork
    /// The app's own stored readings, with gaps while the Mac slept.
    case local
}
