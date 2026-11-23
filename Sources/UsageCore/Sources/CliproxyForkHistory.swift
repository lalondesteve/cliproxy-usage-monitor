import Foundation

/// The fork's `GET /v8/management/quota/history?range=<n>h` (plan.md "Fork's quota
/// poller"): one response for every provider. Only per-account data is read; the
/// fork's pooled numbers don't follow our pool rules.
public struct CliproxyForkHistorySource: ForkHistorySource {
    private let client: CliproxyClient

    public init(config: SourceConfig, transport: any HTTPTransport) {
        self.client = CliproxyClient(config: config, transport: transport)
    }

    /// Exactly one request. `range` is rounded up to whole hours and clamped to the
    /// route's 1h to 720h. A missing route gives `.http(404)`.
    public func fetch(range: TimeInterval) async -> Result<ForkHistoryResponse, SourceError> {
        let query = [URLQueryItem(name: "range", value: "\(Self.rangeHours(range))h")]
        switch await client.get(CliproxyClient.quotaHistoryPath, query: query) {
        case .failure(let e): return .failure(e)
        case .success(let data): return CliproxyForkHistoryParser.parse(data)
        }
    }

    static func rangeHours(_ range: TimeInterval) -> Int {
        guard range.isFinite else { return 720 }
        return Int(min(max((range / 3600).rounded(.up), 1), 720))
    }
}

/// Parses a `quota/history` body, following the live capture (P0.3):
///
/// - `accounts[]`: `account.{id, provider, enabled}`, `status`, and `reading` with
///   `at`, `status` and `windows[]` of `{id: "short" | "weekly", durationSeconds,
///   remaining, resetAt, resetKind}`. API-key credentials (`claude:apikey:...`) show
///   status "unsupported" or "removed" and have no reading.
/// - `pools[]`: `provider`, `window`, and `history[]` knots whose `accounts[]` hold
///   `id`, `status`, `remaining`, `observedAt`, `resetAt`.
/// - Provider "anthropic" is Claude. Timestamps carry up to 9 fractional digits;
///   Go's zero time means unset. Top-level `events[]` and the fork's pooled numbers
///   are ignored.
///
/// The flat shape of the synthetic T6 fixtures (`id` and `provider` on the account,
/// `observedAt` instead of `at`, windows keyed by name) is still read.
/// Values are remaining %, stored as used % (100 - remaining).
enum CliproxyForkHistoryParser {
    /// Statuses of credentials the poller doesn't read. They don't decide whether a
    /// provider is paused: API-key credentials stay "unsupported" whatever the poller
    /// does.
    static let unpolledStatuses: Set<String> = ["unsupported", "removed"]

    static func parse(_ data: Data) -> Result<ForkHistoryResponse, SourceError> {
        guard let root = try? CliproxyJSON.parse(data), root.object != nil else {
            return .failure(.decoding("quota/history is not a JSON object"))
        }
        let accounts = root["accounts"]?.array ?? []
        let pools = root["pools"]?.array ?? []

        // A provider is paused when every polled account says "paused". A provider
        // with no polled account (only API keys, say) is left out: the fork has no
        // readings for it.
        var statuses: [Provider: [String]] = [:]
        var providerOfAccount: [String: Provider] = [:]
        for a in accounts {
            guard let provider = accountProvider(a) else { continue }
            if let id = accountID(a) { providerOfAccount[id] = provider }
            let status = a["status"]?.string?.lowercased() ?? ""
            if !unpolledStatuses.contains(status) { statuses[provider, default: []].append(status) }
        }
        var providers: [Provider: ForkProviderState] = [:]
        for (provider, s) in statuses {
            providers[provider] = s.allSatisfy { $0 == "paused" } ? .paused : .served
        }
        // Only providers with a polled account that aren't paused give readings.
        let served = { (p: Provider) in providers[p] == .served }

        var current: [SourceReading] = []
        for a in accounts {
            guard let provider = accountProvider(a), served(provider),
                  a["status"]?.string?.lowercased() != "paused",
                  let id = accountID(a), let reading = a["reading"],
                  isOK(reading["status"], absentIsOK: true)
            else { continue }
            for (window, w) in windows(reading["windows"]) {
                // The window's own time, else the reading's (`at` live), else the
                // account's; an unset one falls through to the next.
                let times = [w["observedAt"], reading["at"], reading["observedAt"], a["observedAt"]]
                guard isOK(w["status"], absentIsOK: true),
                      let observedAt = times.lazy.compactMap({ $0?.date }).first
                else { continue }
                if let r = sourceReading(provider, id, window, w, observedAt) { current.append(r) }
            }
        }

        struct Key: Hashable { let id: String; let provider: Provider; let window: WindowKind
                               let observedAt: Date }
        var seen = Set<Key>()
        var history: [SourceReading] = []
        for pool in pools {
            guard let window = poolWindow(pool) else { continue }
            let poolProvider = cliproxyProvider(pool["provider"]?.string)
            for knot in pool["history"]?.array ?? [] {
                for e in knot["accounts"]?.array ?? [] {
                    guard let id = accountID(e),
                          let provider = poolProvider ?? cliproxyProvider(e["provider"]?.string)
                              ?? providerOfAccount[id],
                          served(provider),
                          isOK(e["status"], absentIsOK: false),
                          let observedAt = e["observedAt"]?.date,
                          // Validate before claiming the key, so an entry without a
                          // remaining can't hide a later valid one.
                          let r = sourceReading(provider, id, window, e, observedAt),
                          seen.insert(Key(id: id, provider: provider, window: window,
                                          observedAt: observedAt)).inserted
                    else { continue }
                    history.append(r)
                }
            }
        }
        history.sort { ($0.observedAt, $0.fileKey, $0.window.rawValue)
            < ($1.observedAt, $1.fileKey, $1.window.rawValue) }

        return .success(ForkHistoryResponse(providers: providers, current: current,
                                            history: history))
    }

    /// `account.id` on a live account entry; `id` on a history entry and in the flat
    /// account shape.
    private static func accountID(_ node: CliproxyJSON) -> String? {
        node["account"]?["id"]?.nonEmptyString ?? node["id"]?.nonEmptyString
    }

    /// `account.provider` live; `provider` in the flat shape.
    private static func accountProvider(_ node: CliproxyJSON) -> Provider? {
        cliproxyProvider(node["account"]?["provider"]?.nonEmptyString
            ?? node["provider"]?.nonEmptyString)
    }

    private static func isOK(_ status: CliproxyJSON?, absentIsOK: Bool) -> Bool {
        guard let s = status?.string else { return absentIsOK }
        return s.lowercased() == "ok"
    }

    /// Needs a `remaining`; `resetAt` epoch 0 or Go zero time reads as unset (E15).
    private static func sourceReading(_ provider: Provider, _ id: String, _ window: WindowKind,
                                      _ node: CliproxyJSON, _ observedAt: Date) -> SourceReading? {
        guard let remaining = node["remaining"]?.double else { return nil }
        return SourceReading(provider: provider, fileKey: id, window: window,
                             usedPercent: clampPercent(100 - remaining),
                             resetsAt: node["resetAt"]?.date, observedAt: observedAt,
                             source: .forkPoller)
    }

    /// `windows` as an array of objects that name their window (`id` live), or an
    /// object keyed by window name. A window whose name isn't known is classified by
    /// its `durationSeconds`.
    private static func windows(_ node: CliproxyJSON?) -> [(WindowKind, CliproxyJSON)] {
        if let object = node?.object {
            return object.keys.sorted().compactMap { key in
                windowKind(key).map { ($0, CliproxyJSON(object[key]!)) }
            }
        }
        return (node?.array ?? []).compactMap { w in
            let kind = (w["id", "window", "name", "kind", "pool"]?.string).flatMap(windowKind)
                ?? w["durationSeconds"]?.int.flatMap(windowKind(seconds:))
            return kind.map { ($0, w) }
        }
    }

    private static func poolWindow(_ pool: CliproxyJSON) -> WindowKind? {
        for key in ["window", "kind", "pool", "name", "id"] {
            if let name = pool[key]?.string, let kind = windowKind(name) { return kind }
        }
        return pool["durationSeconds"]?.int.flatMap(windowKind(seconds:))
    }

    /// The fork's window lengths: 18000 s is the 5-hour window, 604800 s the weekly one.
    static func windowKind(seconds: Int) -> WindowKind? {
        switch seconds {
        case 18_000: .fiveHour
        case 604_800: .weekly
        default: nil
        }
    }

    /// The fork names its windows "short" and "weekly"; Anthropic-style names are
    /// accepted too. Pool names may carry a provider prefix ("anthropic-short").
    static func windowKind(_ name: String) -> WindowKind? {
        let n = CliproxyJSON.normalize(name)
        if ["short", "5h", "fivehour"].contains(where: n.hasSuffix) { return .fiveHour }
        if ["weekly", "week", "7d", "sevenday"].contains(where: n.hasSuffix) { return .weekly }
        return nil
    }
}
