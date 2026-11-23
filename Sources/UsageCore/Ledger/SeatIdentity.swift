import Foundation

/// plan.md "Identity": a Claude or Codex account is a seat, the provider's key plus
/// the email, written `<key>:<email>` in `AccountID.identity`. Team seats share the
/// key (the Claude organization hash, the Codex `chatgpt_account_id`) but not the
/// quota, so the email tells them apart. Without a usable email the file name stands
/// in for it (`<key>:<fileKey>`), which keeps that file a seat of its own. OpenCode Go
/// keeps its account name.
///
/// Builds before T4b used the key alone. Since T4b no current identity is a bare
/// key: `upgrade` rewrites the key-only identities in snapshots stored by those
/// builds, and `SQLiteHistoryStore.alias(for:)` hands a key-only alias row (which
/// only those builds wrote) to the first seat that has that key.
enum SeatIdentity {
    static let separator: Character = ":"

    /// `<key>:<email>`, or `<key>:<fileKey>` when there is no usable email. Never the
    /// key alone.
    static func make(key: String, email: String?, fileKey: String) -> String {
        "\(key)\(separator)\(usableEmail(email) ?? fileKey)"
    }

    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The normalized email, or nil when it is missing or blank.
    static func usableEmail(_ email: String?) -> String? {
        guard let e = email.map(normalizedEmail), !e.isEmpty else { return nil }
        return e
    }

    /// The key of a seat identity, which was the whole identity before T4b. nil when
    /// the identity isn't a seat (an email alone, an ocgo name).
    static func legacyKey(_ provider: Provider, _ identity: String) -> String? {
        guard provider != .go, let i = identity.firstIndex(of: separator) else { return nil }
        let key = identity[..<i]
        return key.isEmpty || key.contains("@") ? nil : String(key)
    }

    /// The account an alias entry names. A full identity (`<key>:<email>`, or an email
    /// for a legacy Claude file) is used as written. A bare key (`1a2b3c4d`) names the
    /// seat with that key and the aliased file's own email: a legacy file and its
    /// hashed successor are the same login, so they share the email. A Claude listing
    /// without `email` gives the email in the file name; with no email at all the
    /// fallback of `make` applies (`<key>:<fileKey>`). A full identity can name any
    /// account, including a `<key>:<fileKey>` one. A file name (`codex-a.json`, the
    /// identity of a file with neither key nor email) is also used as written: expanding
    /// it as a key would split the pair the alias joins.
    static func aliasTarget(_ alias: String, provider: Provider, fileKey: String, email: String?) -> String {
        guard provider != .go, !alias.contains(separator), !alias.contains("@"),
              !alias.lowercased().hasSuffix(".json")
        else { return alias }
        let email = usableEmail(email) ?? (provider == .claude
            ? CliproxyCredentialsParser.hashedClaudeEmail(fileKey) ?? CliproxyCredentialsParser.legacyClaudeEmail(fileKey)
            : nil)
        return make(key: alias, email: email, fileKey: fileKey)
    }

    /// A stored snapshot's account with the identity this build derives. Snapshots
    /// from builds before T4b carry the key alone for hashed Claude files and Codex
    /// files with a `chatgpt_account_id`; every other identity is unchanged. The
    /// result follows `make`, so a snapshot without an email gives `<key>:<fileKey>`.
    static func upgrade(_ a: AccountSnapshot) -> AccountSnapshot {
        let identity: String
        switch a.id.provider {
        case .claude:
            guard let hash = CliproxyCredentialsParser.claudeHash(a.fileKey), a.id.identity == hash
            else { return a }
            identity = make(key: hash, email: usableEmail(a.email) ?? CliproxyCredentialsParser.hashedClaudeEmail(a.fileKey),
                            fileKey: a.fileKey)
        case .codex:
            // Before T4b a Codex identity was the account id, else the email, else the
            // file name. Only the account id has neither `@` nor the file name.
            let old = a.id.identity
            guard !old.contains(separator), !old.contains("@"), old != a.fileKey else { return a }
            identity = make(key: old, email: a.email, fileKey: a.fileKey)
        case .go:
            return a
        }
        guard identity != a.id.identity else { return a }
        return AccountSnapshot(id: AccountID(provider: a.id.provider, identity: identity),
                               fileKey: a.fileKey, email: a.email, enabled: a.enabled,
                               unavailable: a.unavailable, requestCounter: a.requestCounter,
                               routing: a.routing, polledAt: a.polledAt, pollError: a.pollError)
    }

    static func upgrade(_ s: SourceSnapshot) -> SourceSnapshot {
        let accounts = s.accounts.map(upgrade)
        guard accounts != s.accounts else { return s }
        return SourceSnapshot(source: s.source, takenAt: s.takenAt, accounts: accounts,
                              readings: s.readings, unclassified: s.unclassified, routing: s.routing)
    }
}
