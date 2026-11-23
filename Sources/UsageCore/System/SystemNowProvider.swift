import Foundation

/// The wall clock.
public struct SystemNowProvider: NowProvider {
    public init() {}
    public var now: Date { Date() }
}

/// A clock that always returns the same time (tests, fixture replay).
public struct FixedNowProvider: NowProvider {
    public let now: Date
    public init(_ now: Date) { self.now = now }
}
