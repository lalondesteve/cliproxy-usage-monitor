import Foundation
import Testing
@testable import UsageCore

/// T4b: an account is a seat, the key plus the email (plan.md "Identity", decided
/// 2026-11-23). These tests cover a database written by a build before T4b, whose
/// alias rows and last snapshots use the key alone. Expected aliases follow plan.md
/// "Alias and color" (first-sight order per provider) with the rule that a key-only
/// row goes to the first seat with that key.
@Suite("T4b seat identity")
struct T4bSeatIdentityTests {
    let db = T5TempDatabase()
    let t0 = date("2026-11-23T03:00:00Z")

    static let user4 = "claude-ea14e983-user-4@example.com.json"
    static let user1 = "claude-f5ae9dff-user-1@example.com.json"
    static let user5 = "claude-f5ae9dff-user-5@example.com.json"
    static let codex2 = "codex-85e5a20c-user-2@example.com-team.json"
    static let codex3 = "codex-85e5a20c-user-3@example.com-team.json"
    static let workspace = "00000000-0000-4000-8000-000000000001"

    static func claude(_ identity: String) -> AccountID { AccountID(provider: .claude, identity: identity) }
    static func codex(_ identity: String) -> AccountID { AccountID(provider: .codex, identity: identity) }

    func open() throws -> SQLiteHistoryStore { try SQLiteHistoryStore(path: db.path, retention: nil) }

    static func account(_ id: AccountID, _ file: String, _ email: String?) -> AccountSnapshot {
        AccountSnapshot(id: id, fileKey: file, email: email, enabled: true, unavailable: [],
                        requestCounter: 10, routing: AccountRouting(priority: 0, weight: 1),
                        polledAt: nil, pollError: nil)
    }

    static func weekly(_ provider: Provider, _ file: String, used: Double, at: Date) -> SourceReading {
        SourceReading(provider: provider, fileKey: file, window: .weekly, usedPercent: used, resetsAt: nil,
                      observedAt: at, source: .forkPoller)
    }

    /// What a build before T4b left: alias rows by key, in listing order, and the last
    /// cliproxy snapshot with key-only identities.
    func writeOldDatabase() throws {
        let store = try open()
        #expect(try store.alias(for: Self.claude("ea14e983")) == ("claude-1", 0))
        #expect(try store.alias(for: Self.claude("f5ae9dff")) == ("claude-2", 1))
        #expect(try store.alias(for: Self.codex(Self.workspace)) == ("codex-1", 0))
        try store.append([
            Self.weekly(.claude, Self.user4, used: 30, at: t0),
            Self.weekly(.claude, Self.user1, used: 17, at: t0.addingTimeInterval(-60)),
            Self.weekly(.claude, Self.user5, used: 36, at: t0.addingTimeInterval(-30)),
            Self.weekly(.codex, Self.codex2, used: 43, at: t0),
            Self.weekly(.codex, Self.codex3, used: 24, at: t0.addingTimeInterval(-90)),
        ])
        try store.saveLastSnapshot(SourceSnapshot(source: .cliproxy, takenAt: t0, accounts: [
            Self.account(Self.claude("ea14e983"), Self.user4, "user-4@example.com"),
            Self.account(Self.claude("f5ae9dff"), Self.user1, "user-1@example.com"),
            Self.account(Self.claude("f5ae9dff"), Self.user5, "user-5@example.com"),
            Self.account(Self.codex(Self.workspace), Self.codex2, "user-2@example.com"),
            Self.account(Self.codex(Self.workspace), Self.codex3, "user-3@example.com"),
        ], readings: [], unclassified: [], routing: nil))
        store.close()
    }

    @Test func keyOnlyAliasRowGoesToTheFirstSeatWithThatKey() throws {
        try writeOldDatabase()
        let store = try open()
        // The first seat with each key keeps its alias and color; the second sharing
        // the key is new: next color per provider (Claude 2, Codex 1).
        #expect(try store.alias(for: Self.claude("ea14e983:user-4@example.com")) == ("claude-1", 0))
        #expect(try store.alias(for: Self.claude("f5ae9dff:user-1@example.com")) == ("claude-2", 1))
        #expect(try store.alias(for: Self.claude("f5ae9dff:user-5@example.com")) == ("claude-3", 2))
        #expect(try store.alias(for: Self.codex("\(Self.workspace):user-2@example.com")) == ("codex-1", 0))
        #expect(try store.alias(for: Self.codex("\(Self.workspace):user-3@example.com")) == ("codex-2", 1))
        // An email-only identity (legacy Claude file) isn't a seat with a key.
        #expect(try store.alias(for: Self.claude("x@example.com")) == ("claude-4", 3))
        store.close()

        // Stable across a reopen, in any order.
        let reopened = try open()
        #expect(try reopened.alias(for: Self.codex("\(Self.workspace):user-3@example.com")) == ("codex-2", 1))
        #expect(try reopened.alias(for: Self.claude("f5ae9dff:user-5@example.com")) == ("claude-3", 2))
        #expect(try reopened.alias(for: Self.claude("f5ae9dff:user-1@example.com")) == ("claude-2", 1))
    }

    /// A ledger restored from the old database shows five seats, each with its own
    /// reading (readings are keyed by credential file, so none is lost), and the
    /// aliases above. A fresh poll with seat identities changes nothing.
    @Test func oldDatabaseRestoresAsSeats() throws {
        try writeOldDatabase()
        let store = try open()
        let ledger = Ledger(store: store, settings: PoolSettings())
        try ledger.restore()

        let seats = [Self.claude("ea14e983:user-4@example.com"), Self.claude("f5ae9dff:user-1@example.com"),
                     Self.claude("f5ae9dff:user-5@example.com"),
                     Self.codex("\(Self.workspace):user-2@example.com"),
                     Self.codex("\(Self.workspace):user-3@example.com")]
        #expect(ledger.accounts.map(\.id) == seats)
        #expect(ledger.accounts.map(\.alias) == ["claude-1", "claude-2", "claude-3", "codex-1", "codex-2"])
        #expect(ledger.accounts.map(\.colorIndex) == [0, 1, 2, 0, 1])
        #expect(seats.map { ledger.latest($0, .weekly)?.reading.usedPercent } == [30, 17, 36, 43, 24])

        ledger.apply(SourceSnapshot(source: .cliproxy, takenAt: t0.addingTimeInterval(60), accounts: [
            Self.account(seats[0], Self.user4, "user-4@example.com"),
            Self.account(seats[1], Self.user1, "user-1@example.com"),
            Self.account(seats[2], Self.user5, "user-5@example.com"),
            Self.account(seats[3], Self.codex2, "user-2@example.com"),
            Self.account(seats[4], Self.codex3, "user-3@example.com"),
        ], readings: [], unclassified: [], routing: nil))
        #expect(ledger.accounts.map(\.id) == seats)
        #expect(ledger.accounts.map(\.alias) == ["claude-1", "claude-2", "claude-3", "codex-1", "codex-2"])
    }

    @Test func upgradeTouchesOnlyKeyOnlyIdentities() {
        func upgraded(_ id: AccountID, _ file: String, _ email: String?) -> String {
            SeatIdentity.upgrade(Self.account(id, file, email)).id.identity
        }
        // Key-only: gains the email (listed, or from a hashed Claude file name).
        #expect(upgraded(Self.claude("f5ae9dff"), Self.user1, "User-1@example.com") == "f5ae9dff:user-1@example.com")
        #expect(upgraded(Self.claude("f5ae9dff"), Self.user5, nil) == "f5ae9dff:user-5@example.com")
        #expect(upgraded(Self.codex(Self.workspace), Self.codex2, "user-2@example.com")
                == "\(Self.workspace):user-2@example.com")
        // Already a seat, a legacy email, a Codex email (as older builds wrote it, even
        // untrimmed) or file-name fallback, and Go stay as they are.
        #expect(upgraded(Self.claude("f5ae9dff:user-1@example.com"), Self.user1, "user-1@example.com")
                == "f5ae9dff:user-1@example.com")
        #expect(upgraded(Self.claude("x@example.com"), "claude-x@example.com.json", "x@example.com")
                == "x@example.com")
        #expect(upgraded(Self.codex("user-8@example.com"), "codex-user-8@example.com-plus.json", "User-8@example.com")
                == "user-8@example.com")
        #expect(upgraded(Self.codex("codex-x.json"), "codex-x.json", nil) == "codex-x.json")
        #expect(upgraded(Self.codex(" user-8@example.com "), "codex-y.json", " User-8@example.com ")
                == " user-8@example.com ")
        #expect(upgraded(AccountID(provider: .go, identity: "team-a"), "team-a", nil) == "team-a")
    }

    // MARK: No bare keys (review round 1)

    static func parse(_ json: String) throws -> [CliproxyCredential] {
        try CliproxyCredentialsParser.parse(Data(json.utf8)).get().credentials
    }

    static func snapshot(_ creds: [CliproxyCredential], at: Date) -> SourceSnapshot {
        SourceSnapshot(source: .cliproxy, takenAt: at,
                       accounts: creds.map { account($0.id, $0.fileKey, $0.email) },
                       readings: [], unclassified: [], routing: nil)
    }

    /// (i) Two Codex files in one workspace, neither with an email: the file name
    /// stands in for the email, so they stay two accounts.
    @Test func codexFilesWithoutEmailInOneWorkspaceStaySeparate() throws {
        let creds = try Self.parse("""
            [ { "id": "codex-a.json", "provider": "codex",
                "id_token": { "chatgpt_account_id": "\(Self.workspace)" } },
              { "id": "codex-b.json", "provider": "codex",
                "id_token": { "chatgpt_account_id": "\(Self.workspace)" } } ]
            """)
        #expect(creds.map(\.id) == [Self.codex("\(Self.workspace):codex-a.json"),
                                    Self.codex("\(Self.workspace):codex-b.json")])
        let ledger = Ledger(store: try open(), settings: PoolSettings())
        ledger.apply(Self.snapshot(creds, at: t0))
        #expect(ledger.accounts.map(\.id) == creds.map(\.id))
        #expect(ledger.accounts.map(\.alias) == ["codex-1", "codex-2"])
    }

    /// (ii) A fresh store: a Codex file without an email is listed first, then one with
    /// an email in the same workspace. Each gets its own alias and color. With a bare-key
    /// identity for the first, the second took over its alias row and both showed
    /// `codex-1`, color 0.
    @Test func codexSeatWithEmailDoesNotTakeTheAliasOfOneWithout() throws {
        let creds = try Self.parse("""
            [ { "id": "codex-a.json", "provider": "codex",
                "id_token": { "chatgpt_account_id": "\(Self.workspace)" } },
              { "id": "\(Self.codex2)", "provider": "codex", "email": "user-2@example.com",
                "id_token": { "chatgpt_account_id": "\(Self.workspace)" } } ]
            """)
        let store = try open()
        let ledger = Ledger(store: store, settings: PoolSettings())
        ledger.apply(Self.snapshot(creds, at: t0))
        #expect(ledger.accounts.map(\.alias) == ["codex-1", "codex-2"])
        #expect(ledger.accounts.map(\.colorIndex) == [0, 1])
        // The store agrees, read in the other order.
        #expect(try store.alias(for: Self.codex("\(Self.workspace):user-2@example.com")) == ("codex-2", 1))
        #expect(try store.alias(for: Self.codex("\(Self.workspace):codex-a.json")) == ("codex-1", 0))
    }

    /// (iii) A pre-T4b snapshot of a Codex file with a key-only identity and no email
    /// restores as `<key>:<fileKey>`, and takes over the key-only alias row.
    @Test func restoredCodexKeyWithoutEmailBecomesKeyPlusFileName() throws {
        do {
            let store = try open()
            #expect(try store.alias(for: Self.codex(Self.workspace)) == ("codex-1", 0))
            try store.saveLastSnapshot(SourceSnapshot(source: .cliproxy, takenAt: t0, accounts: [
                Self.account(Self.codex(Self.workspace), "codex-a.json", nil),
            ], readings: [], unclassified: [], routing: nil))
            store.close()
        }
        let ledger = Ledger(store: try open(), settings: PoolSettings())
        try ledger.restore()
        #expect(ledger.accounts.map(\.id) == [Self.codex("\(Self.workspace):codex-a.json")])
        #expect(ledger.accounts.map(\.alias) == ["codex-1"])
    }

    /// B: a Codex file with no account id and the email " User@example.com " is
    /// `user@example.com`, and keeps that identity and its alias across a restore.
    @Test func trimmedEmailIdentitySurvivesRestore() throws {
        let creds = try Self.parse("""
            [ { "id": "codex-u.json", "provider": "codex", "email": " User@example.com " } ]
            """)
        let id = Self.codex("user@example.com")
        #expect(creds.map(\.id) == [id])
        do {
            let store = try open()
            let ledger = Ledger(store: store, settings: PoolSettings())
            let s = Self.snapshot(creds, at: t0)
            try store.saveLastSnapshot(s)
            ledger.apply(s)
            #expect(ledger.accounts.map(\.alias) == ["codex-1"])
            store.close()
        }
        let restored = Ledger(store: try open(), settings: PoolSettings())
        try restored.restore()
        #expect(restored.accounts.map(\.id) == [id])
        #expect(restored.accounts.map(\.alias) == ["codex-1"])
    }

    /// A bare-key alias on a file without an email resolves through the same fallback,
    /// to `<key>:<fileKey>`; a full identity can name a `<key>:<fileKey>` account.
    @Test func aliasesReachFileNameSeats() {
        #expect(SeatIdentity.aliasTarget(Self.workspace, provider: .codex, fileKey: "codex-a.json", email: nil)
                == "\(Self.workspace):codex-a.json")
        #expect(SeatIdentity.aliasTarget(Self.workspace, provider: .codex, fileKey: "codex-a.json", email: " ")
                == "\(Self.workspace):codex-a.json")
        let full = "\(Self.workspace):codex-b.json"
        #expect(SeatIdentity.aliasTarget(full, provider: .codex, fileKey: "codex-a.json", email: nil) == full)
        #expect(SeatIdentity.make(key: "f5ae9dff", email: "  ", fileKey: Self.user1) == "f5ae9dff:\(Self.user1)")
        #expect(SeatIdentity.aliasTarget("codex-a.json", provider: .codex, fileKey: "codex-b.json", email: nil)
                == "codex-a.json")
    }

    /// Round-2 review: two Codex files with neither account id nor email are the
    /// accounts `codex-a.json` and `codex-b.json`. An alias entry joining `codex-b.json`
    /// to `codex-a.json` makes them one account, which keeps A's alias row (`codex-1`,
    /// color 0). Expanding the file name as a key gave `codex-a.json:codex-b.json`, two
    /// accounts, and moved A's live row to the expanded identity: both showed `codex-1`.
    @Test func aliasToAFileNameIdentityJoinsThePair() throws {
        let creds = try Self.parse("""
            [ { "id": "codex-a.json", "provider": "codex" },
              { "id": "codex-b.json", "provider": "codex" } ]
            """)
        #expect(creds.map(\.id) == [Self.codex("codex-a.json"), Self.codex("codex-b.json")])
        let ledger = Ledger(store: try open(),
                            settings: PoolSettings(identityAliases: ["codex-b.json": "codex-a.json"]))
        ledger.apply(Self.snapshot(creds, at: t0))
        #expect(ledger.accounts.map(\.id) == [Self.codex("codex-a.json")])
        #expect(ledger.accounts.map(\.alias) == ["codex-1"])
        #expect(ledger.accounts.map(\.colorIndex) == [0])
        #expect(ledger.accounts.first?.credentials.map(\.fileKey) == ["codex-a.json", "codex-b.json"])
    }
}
