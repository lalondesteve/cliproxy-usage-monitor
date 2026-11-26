import Foundation

public struct AntigravityUsage: Equatable, Sendable {
    public struct Quota: Equatable, Sendable {
        public let remaining: Double
        public let resetsAt: Date?
        public let observedAt: Date
    }

    public let gemini: Quota?
    public let fiveHour: Quota?
    public let weekly: Quota?
    public let checkedAt: Date
    public let waitingForLogin: Bool
}

public actor AntigravitySource {
    private static let host = "https://daily-cloudcode-pa.googleapis.com"
    private let home: URL
    private let transport: any HTTPTransport
    private var account: String?
    private var rejectedToken: String?
    private var gemini: AntigravityUsage.Quota?
    private var fiveHour: AntigravityUsage.Quota?
    private var weekly: AntigravityUsage.Quota?

    public init(transport: any HTTPTransport, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.transport = transport
    }

    func fetch(now: Date) async -> AntigravityUsage? {
        let files = tokenFiles()
        guard !files.isEmpty else {
            selectAccount(nil)
            return nil
        }

        guard let login = files.compactMap(readLogin).max(by: { $0.expiry < $1.expiry }) else {
            return usage(now, waitingForLogin: true)
        }
        selectAccount(login.account)
        guard login.expiry > now, login.token != rejectedToken else {
            return usage(now, waitingForLogin: true)
        }
        rejectedToken = nil

        async let modelRequest = request("fetchAvailableModels", token: login.token, as: Models.self)
        async let summaryRequest = request("retrieveUserQuotaSummary", token: login.token, as: Summary.self)
        let (models, summary) = await (modelRequest, summaryRequest)

        if case .success(let response) = models {
            gemini = response.quota(at: now)
        }
        if case .success(let response) = summary {
            let buckets = response.groups.flatMap(\.buckets)
            fiveHour = buckets.first { $0.bucketId == "3p-5h" && $0.window == "5h" }?.quota(at: now)
            weekly = buckets.first { $0.bucketId == "3p-weekly" && $0.window == "weekly" }?.quota(at: now)
        }
        if case .failure(let first) = models, case .failure(let second) = summary,
           first == .unauthorized || second == .unauthorized {
            rejectedToken = login.token
        }
        return usage(now, waitingForLogin: rejectedToken != nil)
    }

    private func selectAccount(_ next: String?) {
        guard next != account else { return }
        account = next
        rejectedToken = nil
        gemini = nil
        fiveHour = nil
        weekly = nil
    }

    private func usage(_ now: Date, waitingForLogin: Bool) -> AntigravityUsage {
        AntigravityUsage(gemini: gemini, fiveHour: fiveHour, weekly: weekly,
                         checkedAt: now, waitingForLogin: waitingForLogin)
    }

    private func tokenFiles() -> [URL] {
        let manager = FileManager.default
        let root = home.appendingPathComponent(".t3/userdata/providers/antigravity", isDirectory: true)
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                        options: .skipsHiddenFiles)) ?? []
        return folders.sorted(by: { $0.path < $1.path })
            .map { $0.appendingPathComponent("antigravity-acp/antigravity-oauth-token") }
            .filter { manager.fileExists(atPath: $0.path) }
    }

    private func readLogin(_ file: URL) -> Login? {
        guard let data = try? Data(contentsOf: file),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let expiry = WireDate.parse(auth.token.expiry) else { return nil }
        let token = auth.token.access_token
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return Login(account: auth.id_token_email ?? file.path, token: token, expiry: expiry)
    }

    private func request<Response: Decodable>(_ method: String, token: String, as: Response.Type)
        async -> Result<Response, SourceError> {
        var request = URLRequest(url: URL(string: "\(Self.host)/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/1.20.0 darwin/arm64", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(#"{"project":""}"#.utf8)

        do {
            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200 else {
                return .failure(response.statusCode == 401 ? .unauthorized : .http(response.statusCode))
            }
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
                return .failure(.decoding(method))
            }
            return .success(decoded)
        } catch {
            return .failure(.transport(error))
        }
    }

    private struct Login {
        let account: String
        let token: String
        let expiry: Date
    }

    private struct AuthFile: Decodable {
        let token: Token
        let id_token_email: String?

        struct Token: Decodable {
            let access_token: String
            let expiry: String
        }
    }

    private struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?

        func quota(at now: Date) -> AntigravityUsage.Quota? {
            guard let remainingFraction, (0...1).contains(remainingFraction) else { return nil }
            return AntigravityUsage.Quota(remaining: remainingFraction * 100,
                                          resetsAt: WireDate.parse(resetTime), observedAt: now)
        }
    }

    private struct Models: Decodable {
        struct Model: Decodable {
            let quotaInfo: QuotaInfo?
        }

        let models: [String: Model]?

        func quota(at now: Date) -> AntigravityUsage.Quota? {
            models?.compactMap { id, model in
                id.hasPrefix("gemini-") ? model.quotaInfo?.quota(at: now) : nil
            }.min { first, second in
                if first.remaining != second.remaining { return first.remaining < second.remaining }
                return (first.resetsAt ?? .distantFuture) < (second.resetsAt ?? .distantFuture)
            }
        }
    }

    private struct Summary: Decodable {
        struct Group: Decodable {
            let buckets: [Bucket]
        }

        struct Bucket: Decodable {
            let bucketId: String
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?

            func quota(at now: Date) -> AntigravityUsage.Quota? {
                QuotaInfo(remainingFraction: remainingFraction, resetTime: resetTime).quota(at: now)
            }
        }

        let groups: [Group]
    }
}
