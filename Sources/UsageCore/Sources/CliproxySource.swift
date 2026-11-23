import Foundation

/// The cliproxy management API as a `UsageSource` (plan.md "cliproxy").
///
/// `fetch` sends, one after another: the credential list (accounts, counters,
/// routing fields and passive `quota.signals`), the routing strategy, and the config
/// (for session affinity). Any failure of the credential list, and the first auth
/// error anywhere (every 403 counts as one), returns at once with no further request.
/// `takenAt` is the clock reading when the credential list arrived. Another failure of the
/// strategy or config request leaves `routing` nil (unknown) instead of failing the
/// poll, so the passive readings still arrive; `outOfRotation` needs the strategy.
public struct CliproxySource: UsageSource {
    public let kind: SourceKind = .cliproxy
    private let client: CliproxyClient
    private let clock: any NowProvider

    public init(config: SourceConfig, transport: any HTTPTransport, now: any NowProvider) {
        self.client = CliproxyClient(config: config, transport: transport)
        self.clock = now
    }

    /// The URL requests go to: the configured one without `/management.html`.
    public static func baseURL(_ url: URL) -> URL {
        CliproxyClient.baseURL(url)
    }

    /// `since` is unused: the credential list always carries the current signals.
    public func fetch(since: Date?) async -> Result<SourceSnapshot, SourceError> {
        let list: CliproxyCredentialList
        let takenAt: Date
        switch await client.get(CliproxyClient.credentialsPath) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            // The counters are as of this response, not as of the later routing and
            // config calls: a later stamp could put a pre-reset counter after a reset
            // and fake a reset proof (Pool rule 3).
            takenAt = clock.now
            switch CliproxyCredentialsParser.parse(data) {
            case .failure(let e): return .failure(e)
            case .success(let l): list = l
            }
        }

        let strategy: RoutingConfig.Strategy?
        switch await client.get(CliproxyClient.routingStrategyPath) {
        case .failure(let e) where e.isAuthError: return .failure(e)
        case .failure: strategy = nil
        case .success(let data): strategy = CliproxyRoutingParser.strategy(data)
        }

        let affinity: Bool?
        switch await client.get(CliproxyClient.configPath) {
        case .failure(let e) where e.isAuthError: return .failure(e)
        case .failure: affinity = nil
        case .success(let data): affinity = CliproxyRoutingParser.sessionAffinity(data)
        }

        return .success(Self.snapshot(list, strategy: strategy, sessionAffinity: affinity,
                                      takenAt: takenAt))
    }

    /// Exactly one request (the credential list), never retried.
    public func test(_ config: SourceConfig) async -> Result<String, SourceError> {
        let client = CliproxyClient(config: config, transport: self.client.transport)
        switch await client.get(CliproxyClient.credentialsPath) {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            return CliproxyCredentialsParser.parse(data).map {
                "cliproxy answered with \($0.credentials.count) credential(s)"
            }
        }
    }

    static func snapshot(_ list: CliproxyCredentialList, strategy: RoutingConfig.Strategy?,
                         sessionAffinity: Bool?, takenAt: Date) -> SourceSnapshot {
        let accounts = list.credentials.map { c in
            var unavailable: [Unavailability] = []
            // cliproxy says when it retries a quota-blocked credential; that end lets
            // the pool find the refill (Pool rule 5). Without a future retry time,
            // unavailable has no known end.
            if c.upstreamUnavailable {
                if let until = c.unavailableUntil, until > takenAt {
                    unavailable.append(.coolingDown(until: until))
                } else {
                    unavailable.append(.upstreamUnavailable)
                }
            }
            if strategy == .weightedRoundRobin, c.routing.weight <= 0 {
                unavailable.append(.outOfRotation)
            }
            return AccountSnapshot(id: c.id, fileKey: c.fileKey, email: c.email,
                                   enabled: c.enabled, unavailable: unavailable,
                                   requestCounter: c.requestCounter, routing: c.routing,
                                   polledAt: nil, pollError: nil)
        }
        var routing: RoutingConfig?
        if let strategy, let sessionAffinity {
            routing = RoutingConfig(strategy: strategy, sessionAffinity: sessionAffinity,
                                    forcedAccount: nil)
        }
        return SourceSnapshot(source: .cliproxy, takenAt: takenAt, accounts: accounts,
                              readings: list.readings, unclassified: list.unclassified,
                              routing: routing)
    }
}
