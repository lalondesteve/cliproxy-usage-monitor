import Foundation

public protocol HTTPTransport: Sendable {
    /// Returns any HTTP status; throws only for transport failures (URLError).
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public protocol NowProvider: Sendable {
    var now: Date { get }
}

public enum SourceError: Error, Equatable, Hashable, Sendable {
    case unauthorized, remoteManagementDisabled, ipBanned, tlsUntrusted, timeout,
         unreachable, http(Int), decoding(String)

    /// The errors that latch polling (plan.md "Auth failures stop polling").
    public var isAuthError: Bool {
        switch self {
        case .unauthorized, .remoteManagementDisabled, .ipBanned: true
        default: false
        }
    }
}

public struct SourceConfig: Equatable, Sendable {
    public let url: URL
    public let secret: String?

    public init(url: URL, secret: String?) {
        self.url = url
        self.secret = secret
    }
}

/// T1 (minimal ocgo), T6 (cliproxy) and T7 (ocgo) implement.
public protocol UsageSource: Sendable {
    var kind: SourceKind { get }
    /// Requests run one after another; the first auth error (unauthorized,
    /// remoteManagementDisabled, ipBanned) returns at once with no further request.
    func fetch(since: Date?) async -> Result<SourceSnapshot, SourceError>
    /// Exactly one request, never retried.
    func test(_ config: SourceConfig) async -> Result<String, SourceError>
}

public enum ForkProviderState: String, Codable, Equatable, Sendable {
    /// paused: accounts show status "paused"
    case served, paused
}

/// One GET quota/history covers every provider.
public struct ForkHistoryResponse: Equatable, Sendable {
    public let providers: [Provider: ForkProviderState]
    /// accounts[].reading.windows
    public let current: [SourceReading]
    /// pools[].history, deduplicated, status "ok" only
    public let history: [SourceReading]

    public init(providers: [Provider: ForkProviderState], current: [SourceReading],
                history: [SourceReading]) {
        self.providers = providers
        self.current = current
        self.history = history
    }
}

/// T6 implements.
public protocol ForkHistorySource: Sendable {
    /// A missing route gives `.http(404)`.
    func fetch(range: TimeInterval) async -> Result<ForkHistoryResponse, SourceError>
}

/// Coordinator controls: T8 implements, T9c calls.
public protocol PollControl: Sendable {
    /// One request with the given values. Clears the auth latch only when `config`
    /// equals the saved configuration; a failure never clears it.
    func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError>
    /// Only when that source's URL or secret changed; clears its latch.
    func configChanged(_ kind: SourceKind) async
    /// Updates the ledger and the settings passed to PoolEngine, then republishes;
    /// no latch change.
    func poolSettingsChanged(_ settings: PoolSettings) async
}
