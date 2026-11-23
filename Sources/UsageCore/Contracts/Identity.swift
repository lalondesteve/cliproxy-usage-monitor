import Foundation

// Contracts: identity and units. Frozen after the T1 review; changes go through
// the integrator (docs/implementation-plan.md "Contracts").

public enum Provider: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case claude, codex, go
}

public enum WindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour, weekly, monthly
}

/// An account after the identity rule from plan.md "Identity" (before the alias list
/// for `AccountSnapshot.id`; after it for `MergedAccount.id`).
public struct AccountID: Hashable, Codable, Sendable {
    public let provider: Provider
    public let identity: String

    public init(provider: Provider, identity: String) {
        self.provider = provider
        self.identity = identity
    }
}

public enum SourceKind: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case cliproxy, ocgo
}

public enum ReadingSource: String, Codable, CaseIterable, Sendable {
    case passive, forkPoller, ocgo, active
}
