import Foundation
import Testing
@testable import UsageCore

/// Parses the cliproxy captures that `scripts/capture-fixtures.sh` writes to
/// Fixtures/live/ (P0.3). Each test runs only when its own capture is there, and is
/// skipped with a reason until then; don't delete them.
@Suite("T6 live cliproxy fixtures")
struct T6LiveFixtureTests {
    static let credentials = "cliproxy-credentials.json"
    static let strategy = "cliproxy-routing-strategy.json"
    static let config = "cliproxy-config-routing.json"
    static let history = "cliproxy-quota-history-24h.json"

    static func url(_ name: String) -> URL { Fixtures.url("live/\(name)") }
    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static var liveCliproxyFiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Fixtures.url("live").path)) ?? []
        return names.filter { $0.hasPrefix("cliproxy-") && $0.hasSuffix(".json") }.sorted()
    }

    static func missing(_ name: String) -> Comment {
        "No \(name) in Fixtures/live/ yet: P0.3 hasn't run scripts/capture-fixtures.sh"
    }

    let sourceConfig = SourceConfig(url: URL(string: "http://cliproxy.test:8317")!, secret: "k")

    @Test(.enabled(if: !liveCliproxyFiles.isEmpty, missing("cliproxy capture")))
    func everyCliproxyCaptureIsKnown() {
        let known: Set = [Self.credentials, Self.strategy, Self.config, Self.history]
        for name in Self.liveCliproxyFiles where !known.contains(name) {
            Issue.record("live capture \(name) has no T6 parse test")
        }
    }

    @Test(.enabled(if: exists(credentials), missing(credentials)))
    func credentialListParses() async throws {
        var routes: [String: T6RoutedTransport.Reply] = [T6Paths.credentials: .ok(try Self.data(Self.credentials))]
        if Self.exists(Self.strategy) { routes[T6Paths.strategy] = .ok(try Self.data(Self.strategy)) }
        if Self.exists(Self.config) { routes[T6Paths.config] = .ok(try Self.data(Self.config)) }
        let source = CliproxySource(config: sourceConfig, transport: T6RoutedTransport(routes),
                                    now: SystemNowProvider())
        let snapshot = try await source.fetch(since: nil).get()

        #expect(!snapshot.accounts.isEmpty, "no Claude or Codex credential recognised")
        try #require(Set(snapshot.accounts.map(\.fileKey)).count == snapshot.accounts.count)

        // Counter: success + failed when both are whole numbers in the raw JSON,
        // otherwise nil.
        let byFileKey = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.fileKey, $0) })
        for entry in try Self.rawCredentialEntries(try Self.data(Self.credentials)) {
            guard let key = Self.nonBlank(entry["id"]) ?? Self.nonBlank(entry["name"]),
                  let account = byFileKey[key]
            else { continue }
            var expected: Int?
            if let s = Self.wholeNumber(entry["success"]), let f = Self.wholeNumber(entry["failed"]),
               s >= 0, f >= 0 {
                let (sum, overflow) = s.addingReportingOverflow(f)
                expected = overflow ? nil : sum
            }
            #expect(account.requestCounter == expected, "counter of \(key)")
        }
        #expect(snapshot.readings.allSatisfy { (0...100).contains($0.usedPercent) })
        let fileKeys = Set(snapshot.accounts.map(\.fileKey))
        #expect(snapshot.readings.allSatisfy { fileKeys.contains($0.fileKey) })
        if Self.exists(Self.strategy) && Self.exists(Self.config) {
            #expect(snapshot.routing != nil)
        }
    }

    @Test(.enabled(if: exists(strategy), missing(strategy)))
    func routingStrategyParses() throws {
        #expect(CliproxyRoutingParser.strategy(try Self.data(Self.strategy)) != nil)
    }

    @Test(.enabled(if: exists(config), missing(config)))
    func configRoutingParses() throws {
        #expect(CliproxyRoutingParser.sessionAffinity(try Self.data(Self.config)) != nil)
    }

    @Test(.enabled(if: exists(history), missing(history)))
    func forkHistoryParses() async throws {
        let body = try Self.data(Self.history)
        let transport = T6RoutedTransport([T6Paths.history: .ok(body)])
        let response = try await CliproxyForkHistorySource(config: sourceConfig, transport: transport)
            .fetch(range: 24 * 3600).get()
        #expect(!response.providers.isEmpty, "no Claude or Codex account in quota/history")
        for r in response.current + response.history {
            #expect((0...100).contains(r.usedPercent))
            #expect(response.providers[r.provider] == .served)
        }

        let expected = try Self.rawHistoryCount(body)
        if expected.okSamples > 0 {
            #expect(!response.history.isEmpty, "the capture has ok samples but none parsed")
        }
        #expect(response.history.count == expected.deduplicated,
                "parsed history count differs from the raw count")

        // The fork's account.id should be the credential list's id (unverified, P0.2).
        if Self.exists(Self.credentials) {
            let credentialKeys = try CliproxyCredentialsParser.parse(try Self.data(Self.credentials)).get()
                .credentials.map(\.fileKey)
            let unmatched = Set((response.current + response.history).map(\.fileKey))
                .subtracting(credentialKeys)
            #expect(unmatched.isEmpty, "history ids not in the credential list: \(unmatched.sorted())")
        }
    }

    /// Counts history samples straight from the raw JSON with plan.md's literal field
    /// names, independent of the parser: ok entries with a remaining and an observedAt,
    /// for providers listed in accounts[] and not all paused, deduplicated by
    /// (id, provider, pool window, observedAt instant).
    static func rawHistoryCount(_ data: Data) throws -> (okSamples: Int, deduplicated: Int) {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try #require(root["accounts"] as? [[String: Any]], "no accounts array")
        let pools = try #require(root["pools"] as? [[String: Any]], "no pools array")
        func provider(_ any: Any?) -> String? {
            switch (any as? String)?.lowercased() {
            case "anthropic", "claude": "claude"
            case "codex": "codex"
            default: nil
            }
        }
        var statuses: [String: [String]] = [:]
        for a in accounts {
            if let p = provider(a["provider"]) {
                statuses[p, default: []].append((a["status"] as? String ?? "").lowercased())
            }
        }
        let served = Set(statuses.filter { !$0.value.allSatisfy { $0 == "paused" } }.keys)

        struct Key: Hashable { let id: String; let provider: String; let window: String; let at: Date }
        var ok = 0
        var keys = Set<Key>()
        for pool in pools {
            guard let p = provider(pool["provider"]), served.contains(p),
                  let window = pool["window"] as? String, ["short", "weekly"].contains(window)
            else { continue }
            for knot in pool["history"] as? [[String: Any]] ?? [] {
                for e in knot["accounts"] as? [[String: Any]] ?? [] {
                    guard (e["status"] as? String)?.lowercased() == "ok",
                          let remaining = e["remaining"] as? NSNumber,
                          CFGetTypeID(remaining) != CFBooleanGetTypeID(),
                          let id = nonBlank(e["id"]) ?? nonBlank((e["account"] as? [String: Any])?["id"]),
                          let at = instant(e["observedAt"])
                    else { continue }
                    ok += 1
                    keys.insert(Key(id: id, provider: p, window: window, at: at))
                }
            }
        }
        return (ok, keys.count)
    }

    // MARK: - Raw JSON helpers, written apart from the parser's

    static func nonBlank(_ any: Any?) -> String? {
        guard let s = any as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// Integer text only (a JSON integer, or a string of digits) that fits in Int.
    static func wholeNumber(_ any: Any?) -> Int? {
        let text: String
        if let n = any as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            text = n.stringValue
        } else if let s = any as? String {
            text = s.trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        guard text.wholeMatch(of: #/[+-]?[0-9]+/#) != nil else { return nil }
        return Int(text)
    }

    /// RFC 3339 with optional fractional seconds; nil when empty, unparseable, or at or
    /// before epoch 0 (which covers Go's zero time).
    static func instant(_ any: Any?) -> Date? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces),
              let m = s.wholeMatch(of: #/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})/#)
        else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let whole = f.date(from: String(m.1) + String(m.3)) else { return nil }
        let fraction = m.2.flatMap { Double("0" + $0) } ?? 0
        let date = whole.addingTimeInterval(fraction)
        return date.timeIntervalSince1970 > 0 ? date : nil
    }

    /// The array of credential objects: the body itself or under a known wrapper.
    static func rawCredentialEntries(_ data: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: data)
        if let list = root as? [[String: Any]] { return list }
        let object = try #require(root as? [String: Any], "credential list is neither array nor object")
        let wrapped = ["files", "credentials", "auth_files", "items", "data", "accounts"]
            .lazy.compactMap { object[$0] as? [[String: Any]] }.first
        return try #require(wrapped, "no array of credentials in the credential list")
    }
}
