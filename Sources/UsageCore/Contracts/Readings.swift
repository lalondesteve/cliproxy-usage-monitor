import Foundation

/// What sources emit and the store persists: keyed by credential file, never by a
/// resolved account. `fileKey` is the credential list's `id` (its file name), which
/// the fork's quota/history `account.id` also uses; for ocgo, the account name.
public struct SourceReading: Codable, Equatable, Hashable, Sendable {
    public let provider: Provider
    public let fileKey: String
    public let window: WindowKind
    /// 0...100, converted and clamped by the parser
    /// (Claude fraction x100; fork "remaining" -> 100 - x).
    public let usedPercent: Double
    /// nil = unset: missing, epoch 0, or 0001-01-01T00:00:00Z.
    public let resetsAt: Date?
    public let observedAt: Date
    public let source: ReadingSource

    public init(provider: Provider, fileKey: String, window: WindowKind, usedPercent: Double,
                resetsAt: Date?, observedAt: Date, source: ReadingSource) {
        self.provider = provider
        self.fileKey = fileKey
        self.window = window
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.source = source
    }
}

/// What the ledger returns: the same reading with its account resolved at read time
/// from the latest credential list and the Settings alias list.
public struct WindowReading: Equatable, Sendable {
    public let account: AccountID
    public let reading: SourceReading

    public init(account: AccountID, reading: SourceReading) {
        self.account = account
        self.reading = reading
    }
}

/// A window whose length doesn't map to a `WindowKind` (or has no length). Stays out
/// of every pool; shown in hover only.
public struct UnclassifiedReading: Codable, Equatable, Sendable {
    public let provider: Provider
    public let fileKey: String
    public let lengthSeconds: Int?
    public let usedPercent: Double
    public let resetsAt: Date?
    public let observedAt: Date

    public init(provider: Provider, fileKey: String, lengthSeconds: Int?, usedPercent: Double,
                resetsAt: Date?, observedAt: Date) {
        self.provider = provider
        self.fileKey = fileKey
        self.lengthSeconds = lengthSeconds
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}
