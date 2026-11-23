import Foundation

/// One credential file from the credential list, before routing is known.
struct CliproxyCredential: Equatable, Sendable {
    let fileKey: String
    let id: AccountID
    let email: String?
    let enabled: Bool
    let upstreamUnavailable: Bool
    /// When cliproxy retries an unavailable credential: the latest of
    /// `next_retry_after` and the credential-scope `cooldowns[].retry_at`. nil when unset.
    let unavailableUntil: Date?
    let requestCounter: Int?
    let routing: AccountRouting
}

struct CliproxyCredentialList: Equatable, Sendable {
    var credentials: [CliproxyCredential] = []
    var readings: [SourceReading] = []
    var unclassified: [UnclassifiedReading] = []
}

/// Parses `GET /v8/management/credentials` (plan.md "cliproxy", "Identity" and
/// "Reading passive signals"). The live capture (P0.3) wraps the list in `files`;
/// providers other than Claude and Codex (such as `antigravity`) are skipped.
enum CliproxyCredentialsParser {
    static func parse(_ data: Data) -> Result<CliproxyCredentialList, SourceError> {
        let root: CliproxyJSON
        do {
            root = try CliproxyJSON.parse(data)
        } catch {
            return .failure(.decoding("credential list is not JSON"))
        }
        // The list may be the body itself or wrapped (upstream auth-files uses "files").
        guard let entries = root.array
            ?? root["files", "credentials", "auth_files", "items", "data", "accounts"]?.array
        else { return .failure(.decoding("credential list has no array of credentials")) }

        var list = CliproxyCredentialList()
        for entry in entries {
            guard let fileKey = entry["id"]?.nonEmptyString ?? entry["name"]?.nonEmptyString,
                  let provider = cliproxyProvider(entry["provider"]?.nonEmptyString ?? entry["type"]?.nonEmptyString)
            else { continue }
            let email = entry["email"]?.nonEmptyString
            let attributes = entry["attributes"]
            list.credentials.append(CliproxyCredential(
                fileKey: fileKey,
                id: AccountID(provider: provider,
                              identity: identity(provider, fileKey: fileKey, email: email, entry: entry)),
                email: email,
                enabled: !(entry["disabled"]?.bool ?? false),
                upstreamUnavailable: entry["unavailable"]?.bool ?? false,
                unavailableUntil: retryAt(entry),
                requestCounter: requestCounter(entry),
                routing: AccountRouting(
                    priority: entry["priority"]?.int ?? attributes?["priority"]?.int ?? 0,
                    weight: entry["weight"]?.int ?? attributes?["weight"]?.int ?? 1
                )
            ))
            let passive = CliproxyPassiveSignals.readings(provider: provider, fileKey: fileKey,
                                                          quota: entry["quota"])
            list.readings += passive.readings
            list.unclassified += passive.unclassified
        }
        return .success(list)
    }

    /// A quota-blocked credential carries `next_retry_after` and a `cooldowns[]` entry
    /// with `scope: "credential"` and `retry_at`, both the same instant in the live
    /// capture. Model-scope cooldowns don't block the credential. The latest of these
    /// times is the retry: a `next_retry_after` already past mustn't hide a later
    /// credential-scope `retry_at`. CliproxySource treats a time not after `takenAt`
    /// as no known end.
    static func retryAt(_ entry: CliproxyJSON) -> Date? {
        let cooldowns = (entry["cooldowns"]?.array ?? [])
            .filter { $0["scope"]?.string?.lowercased() == "credential" }
            .compactMap { $0["retry_at"]?.date }
        return ([entry["next_retry_after"]?.date].compactMap { $0 } + cooldowns).max()
    }

    /// `success + failed`, or nil unless both are present, whole and non-negative and
    /// their sum fits. Reading a missing counter as 0 could fake an unchanged counter
    /// across a reset (Pool rule 3).
    static func requestCounter(_ entry: CliproxyJSON) -> Int? {
        guard let success = entry["success"]?.int, let failed = entry["failed"]?.int,
              success >= 0, failed >= 0
        else { return nil }
        let (sum, overflow) = success.addingReportingOverflow(failed)
        return overflow ? nil : sum
    }

    /// plan.md "Identity": the seat, the provider's key plus the email (`SeatIdentity`).
    /// Claude's key is the 8-hex hash in `claude-<hash>-<email>.json`; a legacy
    /// `claude-<email>.json` uses the email alone. Codex's key is `chatgpt_account_id`;
    /// without one the email alone. A key without a usable email takes the file name in
    /// the email's place (`SeatIdentity.make`); with neither key nor email the file name
    /// stands alone. Emails are trimmed and lowercased.
    static func identity(_ provider: Provider, fileKey: String, email: String?,
                         entry: CliproxyJSON) -> String {
        switch provider {
        case .claude:
            if let hash = claudeHash(fileKey) {
                return SeatIdentity.make(key: hash, email: SeatIdentity.usableEmail(email) ?? hashedClaudeEmail(fileKey),
                                         fileKey: fileKey)
            }
            return SeatIdentity.usableEmail(email) ?? legacyClaudeEmail(fileKey) ?? fileKey.lowercased()
        case .codex:
            let accountID = entry["id_token"]?["chatgpt_account_id"]?.nonEmptyString
                ?? entry["chatgpt_account_id"]?.nonEmptyString
            if let accountID { return SeatIdentity.make(key: accountID, email: email, fileKey: fileKey) }
            return SeatIdentity.usableEmail(email) ?? fileKey
        case .go:
            return fileKey
        }
    }

    static func claudeHash(_ fileKey: String) -> String? {
        let name = fileKey.lowercased()
        guard name.hasPrefix("claude-") else { return nil }
        let rest = name.dropFirst("claude-".count)
        let hash = rest.prefix(8)
        guard hash.count == 8, hash.allSatisfy(\.isHexDigit),
              rest.dropFirst(8).first == "-", rest.contains("@")
        else { return nil }
        return String(hash)
    }

    /// The email in `claude-<hash>-<email>.json`, for a listing without `email`. It
    /// assumes nothing follows the email but `.json`: a duplicate such as
    /// `claude-aaaa0001-a@example.com-2.json` gives `a@example.com-2`, a separate seat.
    /// Every live listing carries `email`, so this fallback isn't used there.
    static func hashedClaudeEmail(_ fileKey: String) -> String? {
        guard claudeHash(fileKey) != nil else { return nil }
        var email = fileKey.lowercased().dropFirst("claude-".count + 9)
        if email.hasSuffix(".json") { email = email.dropLast(".json".count) }
        return email.contains("@") ? String(email) : nil
    }

    static func legacyClaudeEmail(_ fileKey: String) -> String? {
        let name = fileKey.lowercased()
        guard name.hasPrefix("claude-"), name.hasSuffix(".json") else { return nil }
        let email = name.dropFirst("claude-".count).dropLast(".json".count)
        return email.contains("@") ? String(email) : nil
    }
}

/// plan.md "Reading passive signals": `quota.signals` holds response headers copied
/// from real traffic, `quota.observed_at` when they were seen.
enum CliproxyPassiveSignals {
    static func readings(provider: Provider, fileKey: String, quota: CliproxyJSON?)
        -> (readings: [SourceReading], unclassified: [UnclassifiedReading]) {
        // Without the observation time a reading can't be dated; leave it unknown.
        guard let quota, let observedAt = WireDate.parse(quota["observed_at"]?.string)
        else { return ([], []) }
        let headers = headerMap(quota["signals"])
        switch provider {
        case .claude: return (claude(headers, fileKey: fileKey, observedAt: observedAt), [])
        case .codex: return codex(headers, fileKey: fileKey, observedAt: observedAt)
        case .go: return ([], [])
        }
    }

    /// Lowercased header name to its first value. Values may be strings or string
    /// arrays like Go's `http.Header` (unverified, P0.2), so both are accepted.
    static func headerMap(_ signals: CliproxyJSON?) -> [String: String] {
        guard let object = signals?.object else { return [:] }
        var map: [String: String] = [:]
        for (name, raw) in object {
            let value = CliproxyJSON(raw)
            if let s = value.string ?? value.array?.lazy.compactMap(\.string).first {
                map[name.lowercased()] = s.trimmingCharacters(in: .whitespaces)
            }
        }
        return map
    }

    /// Utilization is a fraction that can exceed 1; resets are epoch seconds.
    static func claude(_ h: [String: String], fileKey: String, observedAt: Date) -> [SourceReading] {
        [(WindowKind.fiveHour, "5h"), (.weekly, "7d")].compactMap { window, tag in
            let prefix = "anthropic-ratelimit-unified-\(tag)-"
            guard let fraction = number(h[prefix + "utilization"]) else { return nil }
            return SourceReading(provider: .claude, fileKey: fileKey, window: window,
                                 usedPercent: clampPercent(fraction * 100),
                                 resetsAt: date(h[prefix + "reset"]),
                                 observedAt: observedAt, source: .passive)
        }
    }

    /// Windows are classified by length, not position: 300 minutes is the 5-hour
    /// window, 10080 the weekly one; anything else, or no length, is unclassified.
    static func codex(_ h: [String: String], fileKey: String, observedAt: Date)
        -> (readings: [SourceReading], unclassified: [UnclassifiedReading]) {
        var readings: [SourceReading] = []
        var unclassified: [UnclassifiedReading] = []
        for slot in ["primary", "secondary"] {
            let prefix = "x-codex-\(slot)-"
            guard let used = number(h[prefix + "used-percent"]) else { continue }
            let resetsAt = date(h[prefix + "reset-at"])
                ?? number(h[prefix + "reset-after-seconds"]).map { observedAt.addingTimeInterval($0) }
            // Out-of-range lengths read as no length; nothing here may trap.
            let minutes = h[prefix + "window-minutes"].flatMap { CliproxyJSON($0).int }
            let lengthSeconds = minutes.flatMap { m -> Int? in
                let (s, overflow) = m.multipliedReportingOverflow(by: 60)
                return overflow ? nil : s
            }
            let window: WindowKind? = switch minutes {
            case 300: .fiveHour
            case 10080: .weekly
            default: nil
            }
            if let window {
                readings.append(SourceReading(provider: .codex, fileKey: fileKey, window: window,
                                              usedPercent: clampPercent(used), resetsAt: resetsAt,
                                              observedAt: observedAt, source: .passive))
            } else {
                unclassified.append(UnclassifiedReading(provider: .codex, fileKey: fileKey,
                                                        lengthSeconds: lengthSeconds,
                                                        usedPercent: clampPercent(used),
                                                        resetsAt: resetsAt, observedAt: observedAt))
            }
        }
        return (readings, unclassified)
    }

    private static func number(_ s: String?) -> Double? {
        s.flatMap { CliproxyJSON($0).double }
    }

    private static func date(_ s: String?) -> Date? {
        s.flatMap { CliproxyJSON($0).date }
    }
}
