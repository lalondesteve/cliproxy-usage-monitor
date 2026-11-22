import Foundation

/// Requests to the cliproxy management API (plan.md "cliproxy"): one `send` per
/// call, never retried, with the management key as `Authorization: Bearer` (the same
/// header `scripts/capture-fixtures.sh` uses by default).
struct CliproxyClient: Sendable {
    static let credentialsPath = "/v8/management/credentials"
    static let routingStrategyPath = "/v0/management/routing/strategy"
    static let configPath = "/v0/management/config"
    static let quotaHistoryPath = "/v8/management/quota/history"

    let config: SourceConfig
    let transport: any HTTPTransport

    /// The configured URL without query, fragment, trailing `/` or a
    /// `/management.html` suffix (any case), so the management page URL works too
    /// (plan.md "Setup screen").
    static func baseURL(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.query = nil
        c.fragment = nil
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        let page = "/management.html"
        if path.lowercased().hasSuffix(page) { path.removeLast(page.count) }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        return c.url ?? url
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard var c = URLComponents(url: Self.baseURL(config.url), resolvingAgainstBaseURL: false)
        else { return nil }
        c.path += path
        c.queryItems = query.isEmpty ? nil : query
        return c.url
    }

    /// Exactly one request, or none when there is no key: a request without one can
    /// only fail, and failed attempts count towards cliproxy's 30-minute IP ban.
    func get(_ path: String, query: [URLQueryItem] = []) async -> Result<Data, SourceError> {
        guard let secret = config.secret, !secret.isEmpty else { return .failure(.unauthorized) }
        guard let url = url(path, query: query) else { return .failure(.unreachable) }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(r)
        } catch {
            return .failure(.transport(error))
        }
        if let error = Self.error(status: response.statusCode, body: data) { return .failure(error) }
        return .success(data)
    }

    /// nil for 2xx. Every 403 from a management route is an auth error, so polling
    /// stops before it can add to the IP ban. Bodies are told apart by text, not
    /// verified against the fork (P0.2): "banned" means the IP ban, "remote management
    /// disabled" means `allow-remote` is off, and any other 403 (empty body included)
    /// is `.unauthorized`.
    static func error(status: Int, body: Data) -> SourceError? {
        switch status {
        case 200..<300:
            return nil
        case 401:
            return .unauthorized
        case 403:
            let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
            if text.contains("banned") { return .ipBanned }
            if text.contains("remote management disabled") { return .remoteManagementDisabled }
            return .unauthorized
        default:
            return .http(status)
        }
    }
}

/// Provider names used by cliproxy and the fork; `"anthropic"` is the fork's name
/// for Claude. Other providers (Gemini, ...) are out of scope and give nil.
func cliproxyProvider(_ name: String?) -> Provider? {
    switch name?.lowercased() {
    case "claude", "anthropic": .claude
    case "codex": .codex
    default: nil
    }
}

func clampPercent(_ value: Double) -> Double {
    min(max(value, 0), 100)
}
