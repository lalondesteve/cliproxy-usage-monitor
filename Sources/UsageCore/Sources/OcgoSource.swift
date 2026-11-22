import Foundation

/// ocgo-proxy `GET /_ocgo/status` (plan.md "ocgo-proxy").
///
/// Reads all three windows (`rolling`, `weekly`, `monthly`), per-account availability
/// and `forced_account`. `OcgoStatusParser` holds the rules.
public struct OcgoSource: UsageSource {
    public let kind: SourceKind = .ocgo
    private let config: SourceConfig
    private let transport: any HTTPTransport
    private let clock: any NowProvider

    public init(config: SourceConfig, transport: any HTTPTransport, now: any NowProvider) {
        self.config = config
        self.transport = transport
        self.clock = now
    }

    public func fetch(since: Date?) async -> Result<SourceSnapshot, SourceError> {
        switch await request(config) {
        case .failure(let e): return .failure(e)
        case .success(let data): return OcgoStatusParser.snapshot(from: data, takenAt: clock.now)
        }
    }

    public func test(_ config: SourceConfig) async -> Result<String, SourceError> {
        switch await request(config) {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            return OcgoStatusParser.snapshot(from: data, takenAt: clock.now).map {
                "ocgo-proxy answered with \($0.accounts.count) account(s)"
            }
        }
    }

    /// Exactly one request.
    private func request(_ config: SourceConfig) async -> Result<Data, SourceError> {
        var r = URLRequest(url: config.url.appending(path: "_ocgo/status"))
        r.httpMethod = "GET"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = config.secret, !secret.isEmpty {
            r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(r)
        } catch {
            return .failure(.transport(error))
        }
        switch response.statusCode {
        case 200..<300: return .success(data)
        case 401: return .failure(.unauthorized)
        default: return .failure(.http(response.statusCode))
        }
    }
}

/// Pure parsing of a `/_ocgo/status` body into a `SourceSnapshot`, following plan.md
/// "ocgo-proxy" and its "Reading the status" rules.
enum OcgoStatusParser {
    struct Payload: Decodable {
        let time: String?
        /// plan.md's sample body doesn't show it; plan.md only says ocgo can pin all
        /// traffic to one account with `forced_account`. Read as an optional top-level
        /// string. Missing, null, empty or another JSON type all mean "not forced".
        let forcedAccount: String?
        let accounts: [Account]

        enum CodingKeys: String, CodingKey {
            case time, forcedAccount, accounts
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = try? c.decodeIfPresent(String.self, forKey: .time)
            forcedAccount = try? c.decodeIfPresent(String.self, forKey: .forcedAccount)
            accounts = try c.decode([Account].self, forKey: .accounts)
        }
    }

    struct Account: Decodable {
        let name: String
        let available: Bool?
        let headroom: Double?
        let exhausted: Bool?
        let exhaustedUntil: String?
        let cooldownUntil: String?
        let polledAt: String?
        let pollError: String?
        let windows: [String: Window]?
    }

    /// Decoded leniently so one bad window can't drop the whole snapshot. A window
    /// that isn't an object, or has any field of the wrong type (`"percent": "n/a"`,
    /// `"resets_at": 12345`), decodes as empty and is skipped like a window that isn't
    /// "ok", so it can't replace the last good reading with a partial one. A missing
    /// or null field is fine (a missing `resets_at` means unset).
    struct Window: Decodable {
        let status: String?
        let percent: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case status, percent, resetsAt
        }

        init(from decoder: any Decoder) throws {
            let fields = try? { () throws -> (String?, Double?, String?) in
                let c = try decoder.container(keyedBy: CodingKeys.self)
                return (try c.decodeIfPresent(String.self, forKey: .status),
                        try c.decodeIfPresent(Double.self, forKey: .percent),
                        try c.decodeIfPresent(String.self, forKey: .resetsAt))
            }()
            (status, percent, resetsAt) = fields ?? (nil, nil, nil)
        }
    }

    /// ocgo window name to pool window (plan.md "Window mapping").
    static let windowNames: [(name: String, kind: WindowKind)] = [
        ("rolling", .fiveHour), ("weekly", .weekly), ("monthly", .monthly),
    ]

    static func snapshot(from data: Data, takenAt: Date) -> Result<SourceSnapshot, SourceError> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            return .failure(.decoding(String(describing: error)))
        }

        let forced = payload.forcedAccount
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        var accounts: [AccountSnapshot] = []
        var readings: [SourceReading] = []
        for a in payload.accounts {
            let polledAt = WireDate.parse(a.polledAt)
            accounts.append(AccountSnapshot(
                id: AccountID(provider: .go, identity: a.name),
                fileKey: a.name,
                email: nil,
                enabled: true,
                unavailable: unavailability(a, forced: forced, at: takenAt),
                requestCounter: nil,
                routing: nil,
                polledAt: polledAt,
                pollError: (a.pollError?.isEmpty ?? true) ? nil : a.pollError
            ))
            readings += windowReadings(a, polledAt: polledAt)
        }

        return .success(SourceSnapshot(
            source: .ocgo,
            takenAt: takenAt,
            accounts: accounts,
            readings: readings,
            unclassified: [],
            routing: RoutingConfig(
                strategy: .mostHeadroom,
                sessionAffinity: false,
                forcedAccount: forced.map { AccountID(provider: .go, identity: $0) }
            )
        ))
    }

    /// One reading per window whose `status` is "ok", observed at `polled_at`.
    ///
    /// - No `polled_at` (or Go's zero time) means never polled: no reading at all.
    ///   Until the first poll ocgo reports headroom 100 and percent 0, which would
    ///   read as full.
    /// - With `poll_error` set, ocgo keeps the last good windows and their
    ///   `polled_at`, so the reading comes out with that old `observedAt`, the same
    ///   reading the last good poll gave. Nothing newer is made up; the ledger shows
    ///   it with its age.
    /// - A window past its `resets_at` is reported as is (old percent, old
    ///   `observedAt`). Whether it counts as reset is Pool rule 3's call
    ///   (`observedAt >= resetsAt`), not the source's.
    static func windowReadings(_ a: Account, polledAt: Date?) -> [SourceReading] {
        guard let observedAt = polledAt, let windows = a.windows else { return [] }
        return windowNames.compactMap { name, kind in
            guard let w = windows[name], w.status == "ok",
                  let percent = w.percent, percent.isFinite
            else { return nil }
            return SourceReading(
                provider: .go,
                fileKey: a.name,
                window: kind,
                usedPercent: min(max(percent, 0), 100),
                resetsAt: WireDate.parse(w.resetsAt),
                observedAt: observedAt,
                source: .ocgo
            )
        }
    }

    /// Why an account isn't usable now (plan.md "Reading the status", Pool rule 4).
    ///
    /// - With `forced_account` set, every other account is `notForcedAccount`
    ///   (ocgo doesn't fail over), followed by its own reasons when ocgo calls it
    ///   unavailable. The forced account skips ocgo's availability check, so it gets
    ///   no account-level reason at all, whatever `available`, `exhausted` and
    ///   `cooldown_until` say: only its windows decide whether it is usable.
    /// - Otherwise "usable now" follows `available`. When it is false, `exhausted`
    ///   (until `exhausted_until`) and a `cooldown_until` still in the future say
    ///   why. With neither, the account is still unavailable: `upstreamUnavailable`.
    static func unavailability(_ a: Account, forced: String?, at now: Date) -> [Unavailability] {
        let exhausted: Unavailability? = (a.exhausted ?? false)
            ? .exhausted(until: WireDate.parse(a.exhaustedUntil)) : nil
        let cooldown: Unavailability? = WireDate.parse(a.cooldownUntil)
            .flatMap { $0 > now ? .coolingDown(until: $0) : nil }
        let own = [exhausted, cooldown].compactMap { $0 }
        let available = a.available ?? true

        if let forced {
            if a.name == forced { return [] }
            return [.notForcedAccount] + (available ? [] : own)
        }
        if available { return [] }
        return own.isEmpty ? [.upstreamUnavailable] : own
    }
}
