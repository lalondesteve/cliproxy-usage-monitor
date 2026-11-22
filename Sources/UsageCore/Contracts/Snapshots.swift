import Foundation

public enum Unavailability: Codable, Equatable, Sendable {
    /// cliproxy `unavailable`
    case upstreamUnavailable
    /// weight <= 0 under weighted-round-robin
    case outOfRotation
    /// ocgo
    case exhausted(until: Date?)
    /// ocgo
    case coolingDown(until: Date?)
    /// ocgo `forced_account` names another account
    case notForcedAccount
}

public struct AccountRouting: Codable, Equatable, Sendable {
    public let priority: Int
    public let weight: Int

    public init(priority: Int, weight: Int) {
        self.priority = priority
        self.weight = weight
    }
}

/// One per credential file or ocgo account.
public struct AccountSnapshot: Codable, Equatable, Sendable {
    /// Identity rule from plan.md "Identity", before the alias list.
    public let id: AccountID
    /// Credential name or ocgo account name.
    public let fileKey: String
    public let email: String?
    public let enabled: Bool
    /// Empty = the source calls it available.
    public let unavailable: [Unavailability]
    /// cliproxy success + failed; nil for ocgo.
    public let requestCounter: Int?
    public let routing: AccountRouting?
    /// ocgo
    public let polledAt: Date?
    /// ocgo
    public let pollError: String?

    public init(id: AccountID, fileKey: String, email: String?, enabled: Bool,
                unavailable: [Unavailability], requestCounter: Int?, routing: AccountRouting?,
                polledAt: Date?, pollError: String?) {
        self.id = id
        self.fileKey = fileKey
        self.email = email
        self.enabled = enabled
        self.unavailable = unavailable
        self.requestCounter = requestCounter
        self.routing = routing
        self.polledAt = polledAt
        self.pollError = pollError
    }
}

public struct RoutingConfig: Codable, Equatable, Sendable {
    /// Raw values are cliproxy's `routing.strategy` strings; `mostHeadroom` is ocgo's
    /// fixed strategy.
    public enum Strategy: String, Codable, CaseIterable, Sendable {
        case roundRobin = "round-robin"
        case weightedRoundRobin = "weighted-round-robin"
        case fillFirst = "fill-first"
        case mostHeadroom = "most-headroom"
    }

    public let strategy: Strategy
    public let sessionAffinity: Bool
    public let forcedAccount: AccountID?

    public init(strategy: Strategy, sessionAffinity: Bool, forcedAccount: AccountID?) {
        self.strategy = strategy
        self.sessionAffinity = sessionAffinity
        self.forcedAccount = forcedAccount
    }
}

/// One source poll. The store persists it (`HistoryStore.saveLastSnapshot`).
public struct SourceSnapshot: Codable, Equatable, Sendable {
    public let source: SourceKind
    public let takenAt: Date
    public let accounts: [AccountSnapshot]
    public let readings: [SourceReading]
    public let unclassified: [UnclassifiedReading]
    public let routing: RoutingConfig?

    public init(source: SourceKind, takenAt: Date, accounts: [AccountSnapshot],
                readings: [SourceReading], unclassified: [UnclassifiedReading],
                routing: RoutingConfig?) {
        self.source = source
        self.takenAt = takenAt
        self.accounts = accounts
        self.readings = readings
        self.unclassified = unclassified
        self.routing = routing
    }
}
