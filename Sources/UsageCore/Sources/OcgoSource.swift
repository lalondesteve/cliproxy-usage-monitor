import Foundation

/// ocgo-proxy `GET /_ocgo/status` (plan.md "ocgo-proxy").
///
/// T1 scope: the 5-hour `rolling` window only, read when the account was polled and
/// the window's status is "ok". T7 adds weekly and monthly, `poll_error` handling,
/// availability reasons in full and `forced_account`.
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

/// Pure parsing of a `/_ocgo/status` body into a `SourceSnapshot`.
enum OcgoStatusParser {
    struct Payload: Decodable {
        let time: String?
        let forcedAccount: String?
        let accounts: [Account]
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

    struct Window: Decodable {
        let status: String?
        let percent: Double?
        let resetsAt: String?
    }

    static func snapshot(from data: Data, takenAt: Date) -> Result<SourceSnapshot, SourceError> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            return .failure(.decoding(String(describing: error)))
        }

        var accounts: [AccountSnapshot] = []
        var readings: [SourceReading] = []
        for a in payload.accounts {
            let polledAt = WireDate.parse(a.polledAt)
            accounts.append(AccountSnapshot(
                id: AccountID(provider: .go, identity: a.name),
                fileKey: a.name,
                email: nil,
                enabled: true,
                unavailable: unavailability(a),
                requestCounter: nil,
                routing: nil,
                polledAt: polledAt,
                pollError: (a.pollError?.isEmpty ?? true) ? nil : a.pollError
            ))
            // Never polled: headroom 100 and percent 0 would read as full. Unknown.
            guard let observedAt = polledAt,
                  let rolling = a.windows?["rolling"],
                  rolling.status == "ok",
                  let percent = rolling.percent
            else { continue }
            readings.append(SourceReading(
                provider: .go,
                fileKey: a.name,
                window: .fiveHour,
                usedPercent: min(max(percent, 0), 100),
                resetsAt: WireDate.parse(rolling.resetsAt),
                observedAt: observedAt,
                source: .ocgo
            ))
        }

        let forced = payload.forcedAccount.flatMap { $0.isEmpty ? nil : $0 }
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

    /// T1 keeps this coarse; T7 implements the full rules (forced account, advisory
    /// cooldown).
    private static func unavailability(_ a: Account) -> [Unavailability] {
        if a.available ?? true { return [] }
        if a.exhausted ?? false { return [.exhausted(until: WireDate.parse(a.exhaustedUntil))] }
        return [.coolingDown(until: WireDate.parse(a.cooldownUntil))]
    }
}
