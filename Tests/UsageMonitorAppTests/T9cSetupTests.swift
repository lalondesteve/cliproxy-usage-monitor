import Foundation
import Testing
import UsageCore
@testable import UsageMonitorApp

private let cliproxyURL = t9cCliproxyURL
private let ocgoURL = t9cOcgoURL
private let savedSettings = t9cSavedSettings
private typealias Harness = T9cHarness

@Suite("T9c Test messages")
struct T9cMessageTests {
    /// plan.md "Setup screen": wrong key, allow-remote off, untrusted TLS (trust the
    /// private CA in the macOS Keychain), timeout; Data sources: 5 bad attempts ban the
    /// IP for 30 min. The switch keeps this exhaustive when a case is added.
    @Test func eachSourceErrorHasItsSentence() {
        let all: [SourceError] = [.unauthorized, .remoteManagementDisabled, .ipBanned, .tlsUntrusted,
                                  .timeout, .unreachable, .http(503), .decoding("missing key files")]
        var sentences: Set<String> = []
        for error in all {
            let text = SetupMessages.sentence(for: error, kind: .cliproxy)
            sentences.insert(text)
            #expect(text.hasSuffix("."), "\(error): one sentence")
            switch error {
            case .unauthorized:
                #expect(text.contains("refused the request"))
                #expect(text.contains("5 failed attempts"))
            case .remoteManagementDisabled:
                #expect(text.contains("allow-remote"))
                #expect(text.contains("Remote management is disabled"))
            case .ipBanned:
                #expect(text.contains("banned"))
                #expect(text.contains("Wait 30 minutes"))
                #expect(text.contains("5 failed attempts"))
            case .tlsUntrusted:
                #expect(text.contains("Untrusted TLS certificate"))
                #expect(text.contains("Keychain Access"))
            case .timeout:
                #expect(text.contains("timed out"))
            case .unreachable:
                #expect(text.contains("Couldn't reach the server"))
            case .http(let code):
                #expect(text.contains("HTTP \(code)"))
            case .decoding(let detail):
                #expect(text.contains(detail))
                #expect(text.contains("Unexpected response"))
            }
        }
        #expect(sentences.count == all.count)
        #expect(SetupMessages.sentence(for: .http(404), kind: .cliproxy).contains("HTTP 404"))
        // Only a 401 depends on the source.
        for error in all where error != .unauthorized {
            #expect(SetupMessages.sentence(for: error, kind: .ocgo)
                == SetupMessages.sentence(for: error, kind: .cliproxy))
        }
    }

    /// cliproxy's ban after 5 bad keys doesn't apply to ocgo-proxy.
    @Test func ocgoRejectedTokenDoesNotMentionTheBan() {
        let text = SetupMessages.sentence(for: .unauthorized, kind: .ocgo)
        #expect(text.contains("Wrong client token"))
        #expect(!text.contains("ban"))
        #expect(!text.contains("failed attempts"))
    }

    @Test func successNamesWhatTheSourceReturned() {
        #expect(SetupMessages.result(.success("3 credentials"), kind: .cliproxy) == "Connected: 3 credentials")
        #expect(SetupMessages.result(.failure(.timeout), kind: .ocgo)
            == SetupMessages.sentence(for: .timeout, kind: .ocgo))
    }
}

@Suite("T9c Test button")
@MainActor
struct T9cTestButtonTests {
    @Test func testSendsTheFormValuesOnce() async throws {
        let h = try await Harness().loaded()
        h.model.form.cliproxyURL = " https://cliproxy.example:8317/management.html "
        h.model.form.cliproxyKey.value = "typed-key\n"
        await h.model.test(.cliproxy)
        let expected = SourceConfig(url: URL(string: "https://cliproxy.example:8317")!, secret: "typed-key")
        #expect(await h.calls == [.test(.cliproxy, expected)])
        #expect(h.model.testState(.cliproxy) == .succeeded("Connected: 3 credentials"))
        // Testing saves nothing.
        #expect(h.store.load() == savedSettings)
        #expect(h.secrets.writes.isEmpty)
    }

    @Test func failureIsShownInWordsAndNotRetried() async throws {
        let h = try await Harness().loaded()
        await h.poll.setTestResult(.failure(.ipBanned))
        await h.model.test(.cliproxy)
        #expect(await h.calls == [.test(.cliproxy, SourceConfig(url: cliproxyURL, secret: "old-key"))])
        #expect(h.model.testState(.cliproxy) == .failed(SetupMessages.sentence(for: .ipBanned, kind: .cliproxy)))
    }

    @Test func ocgoTestUsesTheOcgoFields() async throws {
        let h = try await Harness().loaded()
        h.model.form.ocgoToken.value = "new-token"
        await h.model.test(.ocgo)
        #expect(await h.calls == [.test(.ocgo, SourceConfig(url: ocgoURL, secret: "new-token"))])
    }

    @Test func cliproxyTestWithoutKeySendsNothing() async throws {
        let h = try await Harness(secrets: [:]).loaded()
        await h.model.test(.cliproxy)
        #expect(await h.calls.isEmpty)
        #expect(h.model.testState(.cliproxy) == .failed(SetupFormError.missingKey.message))
    }

    @Test func invalidOrMissingURLSendsNothing() async throws {
        let h = try await Harness().loaded()
        h.model.form.ocgoURL = ""
        await h.model.test(.ocgo)
        h.model.form.cliproxyURL = "ftp://cliproxy"
        await h.model.test(.cliproxy)
        #expect(await h.calls.isEmpty)
        #expect(h.model.testState(.ocgo) == .failed(SetupFormError.missingURL(.ocgo).message))
        #expect(h.model.testState(.cliproxy) == .failed(SetupFormError.invalidURL(.cliproxy).message))
    }
}

@Suite("T9c Save")
@MainActor
struct T9cSaveTests {
    @Test func loadFillsTheFormFromSettingsAndKeychain() async throws {
        let h = try await Harness().loaded()
        #expect(h.model.phase == .ready)
        #expect(h.model.form.cliproxyURL == cliproxyURL.absoluteString)
        #expect(h.model.form.cliproxyKey.value == "old-key")
        #expect(h.model.form.ocgoToken.value == "old-token")
        #expect(h.model.form.staleMinutes == "30")
        #expect(h.model.form.aliases.map { [$0.fileKey, $0.identity] } == [["claude-x@example.com.json", "1a2b3c4d"]])
    }

    @Test func aliasChangeCallsOnlyPoolSettingsChanged() async throws {
        let h = try await Harness().loaded()
        h.model.form.aliases.append(AliasRow(fileKey: "claude-y@example.com.json", identity: "5e6f7a8b"))
        await h.model.save()
        let pool = PoolSettings(staleAfter: 1800, identityAliases: [
            "claude-x@example.com.json": "1a2b3c4d", "claude-y@example.com.json": "5e6f7a8b"])
        #expect(await h.calls == [.poolSettingsChanged(pool)])
        #expect(h.model.saveState == .saved)
        #expect(h.store.load()?.pool == pool)
    }

    @Test func removingAnAliasCallsOnlyPoolSettingsChanged() async throws {
        let h = try await Harness().loaded()
        h.model.form.aliases.removeAll()
        await h.model.save()
        #expect(await h.calls == [.poolSettingsChanged(PoolSettings(staleAfter: 1800, identityAliases: [:]))])
    }

    @Test func staleThresholdChangeCallsOnlyPoolSettingsChanged() async throws {
        let h = try await Harness().loaded()
        h.model.form.staleMinutes = "10"
        await h.model.save()
        var pool = savedSettings.pool
        pool.staleAfter = 600
        #expect(await h.calls == [.poolSettingsChanged(pool)])
    }

    @Test func menubarStyleAloneCallsNeither() async throws {
        let h = try await Harness().loaded()
        h.model.form.menubarStyle = .compact
        await h.model.save()
        #expect(await h.calls.isEmpty)
        #expect(h.store.load()?.menubarStyle == .compact)
        #expect(h.savedCallbacks.map(\.menubarStyle) == [.compact])
        #expect(h.secrets.writes.isEmpty)
    }

    /// The style applies and is stored without Save, and doesn't save other edits.
    @Test func menubarStyleAppliesWithoutSave() async throws {
        let h = try await Harness().loaded()
        var applied: [MenubarStyle] = []
        h.model.onMenubarStyle = { applied.append($0) }
        h.model.form.staleMinutes = "10"
        h.model.setMenubarStyle(.compact)
        #expect(applied == [.compact])
        var expected = savedSettings
        expected.menubarStyle = .compact
        #expect(h.store.load() == expected)
        #expect(h.model.settings == expected)
        #expect(h.model.form.staleMinutes == "10")
        #expect(await h.calls.isEmpty)
        #expect(h.savedCallbacks.isEmpty)

        h.model.setMenubarStyle(.compact)
        #expect(applied == [.compact])
        // A reopened window shows the stored style.
        await h.model.load()
        #expect(h.model.form.menubarStyle == .compact)
    }

    @Test func unchangedSaveCallsNothing() async throws {
        let h = try await Harness().loaded()
        await h.model.save()
        #expect(await h.calls.isEmpty)
        #expect(h.secrets.writes.isEmpty)
    }

    @Test func changedCliproxyURLCallsConfigChanged() async throws {
        let h = try await Harness().loaded()
        h.model.form.cliproxyURL = "http://100.64.0.2:8317"
        await h.model.save()
        #expect(await h.calls == [.configChanged(.cliproxy)])
        #expect(h.store.load()?.cliproxyURL == URL(string: "http://100.64.0.2:8317"))
        #expect(h.secrets.writes.isEmpty)
    }

    @Test func changedCliproxyKeyCallsConfigChangedAndWritesItsAccount() async throws {
        let h = try await Harness().loaded()
        h.model.form.cliproxyKey.value = "new-key"
        await h.model.save()
        #expect(await h.calls == [.configChanged(.cliproxy)])
        #expect(h.secrets.writes == ["write cliproxy-key"])
        #expect(h.secrets.stored[.cliproxyKey] == "new-key")
        #expect(h.secrets.stored[.ocgoToken] == "old-token")
        #expect(h.secrets.stored[.debugTestToken] == nil)
        // A second save with nothing new calls nothing: the baseline moved.
        await h.model.save()
        #expect(await h.calls == [.configChanged(.cliproxy)])
    }

    @Test func sameURLWrittenDifferentlyIsNoChange() async throws {
        let h = try await Harness().loaded()
        h.model.form.cliproxyURL = "http://100.64.0.1:8317/management.html"
        await h.model.save()
        #expect(await h.calls.isEmpty)
    }

    @Test func secretAndPoolChangesCallBoth() async throws {
        let h = try await Harness().loaded()
        h.model.form.ocgoToken.value = "new-token"
        h.model.form.staleMinutes = "45"
        await h.model.save()
        var pool = savedSettings.pool
        pool.staleAfter = 2700
        #expect(await h.calls == [.configChanged(.ocgo), .poolSettingsChanged(pool)])
    }

    @Test func emptyOcgoURLMeansOcgoNotConfigured() async throws {
        let h = try await Harness().loaded()
        #expect(h.model.form.ocgoConfigured)
        h.model.form.ocgoURL = "   "
        #expect(!h.model.form.ocgoConfigured)
        await h.model.save()
        let saved = try #require(h.store.load())
        #expect(saved.ocgoURL == nil)
        #expect(!saved.ocgoConfigured)
        #expect(saved.isConfigured(.cliproxy))
        #expect(await h.calls == [.configChanged(.ocgo)])
        #expect(h.savedCallbacks.map(\.ocgoConfigured) == [false])
        #expect(!AppSettings().ocgoConfigured)
    }

    @Test func clearingASecretDeletesIt() async throws {
        let h = try await Harness().loaded()
        h.model.form.ocgoURL = ""
        h.model.form.ocgoToken.value = ""
        await h.model.save()
        #expect(h.secrets.writes == ["delete ocgo-token"])
        #expect(await h.calls == [.configChanged(.ocgo)])
    }

    @Test func unreadableSecretLeftEmptyIsKept() async throws {
        let h = try Harness()
        h.secrets.failReads(.cliproxyKey)
        await h.model.load()
        guard case .unreadable = h.model.form.cliproxyKey.baseline else {
            Issue.record("expected an unreadable baseline")
            return
        }
        #expect(h.model.form.cliproxyKey.value == "")
        h.model.form.menubarStyle = .compact
        await h.model.save()
        #expect(h.model.saveState == .saved)
        #expect(h.secrets.writes.isEmpty)
        #expect(h.secrets.stored[.cliproxyKey] == "old-key")
        #expect(await h.calls.isEmpty)
    }

    @Test func keychainFailureSavesNothingAndCallsNothing() async throws {
        let h = try await Harness().loaded()
        h.secrets.failAllWrites()
        h.model.form.cliproxyKey.value = "new-key"
        h.model.form.staleMinutes = "10"
        await h.model.save()
        guard case .failed = h.model.saveState else {
            Issue.record("expected a failed save, got \(h.model.saveState)")
            return
        }
        #expect(await h.calls.isEmpty)
        #expect(h.store.load() == savedSettings)
        #expect(h.savedCallbacks.isEmpty)
    }

    @Test func invalidFormSavesNothing() async throws {
        let cases: [(String, (inout SetupForm) -> Void, SetupFormError)] = [
            ("stale zero", { $0.staleMinutes = "0" }, .invalidStaleMinutes),
            ("stale text", { $0.staleMinutes = "ten" }, .invalidStaleMinutes),
            ("half alias", { $0.aliases.append(AliasRow(fileKey: "claude-z.json")) }, .incompleteAlias(row: 2)),
            ("dup alias", { $0.aliases.append(AliasRow(fileKey: "claude-x@example.com.json", identity: "x")) },
             .duplicateAlias("claude-x@example.com.json")),
            ("bad url", { $0.ocgoURL = "not a url" }, .invalidURL(.ocgo)),
            ("no key", { $0.cliproxyKey.value = "" }, .missingKey),
        ]
        for (name, edit, error) in cases {
            let h = try await Harness().loaded()
            edit(&h.model.form)
            await h.model.save()
            #expect(h.model.saveState == .failed(error.message), "\(name)")
            #expect(await h.calls.isEmpty, "\(name)")
            #expect(h.store.load() == savedSettings, "\(name)")
        }
    }

    @Test func blankAliasRowsAreDropped() async throws {
        let h = try await Harness().loaded()
        h.model.form.aliases.append(AliasRow(fileKey: "  ", identity: ""))
        await h.model.save()
        #expect(await h.calls.isEmpty)
    }
}

@Suite("T9c Settings storage")
struct T9cStorageTests {
    @Test func settingsSurviveANewStoreOnTheSameDefaults() throws {
        let suite = T9cDefaults()
        #expect(SettingsStore(defaults: suite.defaults).load() == nil)
        var settings = savedSettings
        settings.menubarStyle = .compact
        settings.activeCallsEnabled = true
        try SettingsStore(defaults: suite.defaults).save(settings)
        // A relaunch reads through a fresh store.
        #expect(SettingsStore(defaults: suite.defaults).load() == settings)
    }

    @Test func formKeepsFieldsItDoesNotShow() throws {
        var base = savedSettings
        base.activeCallsEnabled = true
        let form = SetupForm(settings: base, cliproxyKey: .loaded("k"), ocgoToken: .loaded(nil))
        let request = try form.saveRequest(base: base).get()
        #expect(request.settings == base)
        #expect(request.cliproxyKey == .unchanged)
        #expect(request.ocgoToken == .unchanged)
    }

    @Test func needsSetupUntilASourceHasAURL() {
        #expect(SetupWindowController.needsSetup(settings: AppSettings()))
        #expect(!SetupWindowController.needsSetup(settings: AppSettings(cliproxyURL: cliproxyURL)))
        #expect(!SetupWindowController.needsSetup(settings: AppSettings(ocgoURL: ocgoURL)))
    }

    @Test func secretsUseTheirOwnAccounts() {
        #expect(Keychain.Account.secret(for: .cliproxy) == .cliproxyKey)
        #expect(Keychain.Account.secret(for: .ocgo) == .ocgoToken)
        #expect(Keychain.Account.cliproxyKey.rawValue != Keychain.Account.debugTestToken.rawValue)
        #expect(Keychain.Account.cliproxyKey.rawValue != Keychain.Account.ocgoToken.rawValue)
        #expect(Keychain.defaultService == "ca.lals.usage-monitor")
    }

    @Test func diffIsPure() {
        var new = savedSettings
        new.menubarStyle = .compact
        new.ocgoURL = nil
        let request = SaveRequest(settings: new, cliproxyKey: .set("k"), ocgoToken: .unchanged)
        let changes = SettingsDiff.changes(from: savedSettings, to: request)
        #expect(changes == SettingsChanges(configChanged: [.cliproxy, .ocgo], poolSettings: nil))
    }
}

@Suite("Test retry confirmation")
@MainActor
struct TestRetryConfirmationTests {
    /// cliproxy bans the IP after 5 wrong keys, so a Test after a rejected key asks first.
    /// The count survives an edited key and a reopened window; a success clears it.
    @Test func aRejectedKeyMakesTheNextTestAsk() async throws {
        let h = try await T9cHarness().loaded()
        #expect(!h.model.confirmsTest(.cliproxy))

        await h.poll.setTestResult(.failure(.unauthorized))
        await h.model.test(.cliproxy)
        #expect(h.model.confirmsTest(.cliproxy))
        #expect(!h.model.confirmsTest(.ocgo))

        h.model.form.cliproxyKey.value = "another-key"
        await h.model.load()
        await h.model.test(.cliproxy)
        #expect(h.model.cliproxyRejections == 2)
        #expect(SetupView.retryWarning(2).contains("2 times"))
        #expect(SetupView.retryWarning(1).contains("once"))

        await h.poll.setTestResult(.failure(.timeout))
        await h.model.test(.cliproxy)
        #expect(h.model.cliproxyRejections == 2)

        await h.poll.setTestResult(.success("3 credentials"))
        await h.model.test(.cliproxy)
        #expect(!h.model.confirmsTest(.cliproxy))
    }

    /// ocgo-proxy has no ban, so its 401 never asks.
    @Test func ocgoRejectionsDoNotAsk() async throws {
        let h = try await T9cHarness().loaded()
        await h.poll.setTestResult(.failure(.unauthorized))
        await h.model.test(.ocgo)
        #expect(!h.model.confirmsTest(.ocgo))
        #expect(!h.model.confirmsTest(.cliproxy))
    }
}
