import AppKit
import Foundation
import Testing
import UsageCore
@testable import UsageMonitorApp

private let cliproxyURL = t9cCliproxyURL
private let savedSettings = t9cSavedSettings
private typealias Harness = T9cHarness

@Suite("T9c URLs")
@MainActor
struct T9cURLTests {
    private func parsed(_ text: String) -> Result<URL?, SetupFormError> {
        SetupForm.parseURL(text, kind: .cliproxy)
    }

    /// plan.md "Setup screen": accept the management page URL and strip `/management.html`.
    @Test func pastedManagementPageForms() {
        let base = URL(string: "http://100.64.0.1:8317")!
        #expect(parsed("http://100.64.0.1:8317/management.html/") == .success(base))
        #expect(parsed("http://100.64.0.1:8317/management.html#/dashboard") == .success(base))
        #expect(parsed("http://100.64.0.1:8317/management.html?tab=keys") == .success(base))
        #expect(parsed("HTTP://100.64.0.1:8317/Management.HTML") == .success(base))
        #expect(parsed("http://100.64.0.1:8317///") == .success(base))
        #expect(parsed("https://host.example/proxy/management.html")
            == .success(URL(string: "https://host.example/proxy")!))
        #expect(parsed("  ") == .success(nil))
        #expect(parsed("ftp://host") == .failure(.invalidURL(.cliproxy)))
        #expect(parsed("http://") == .failure(.invalidURL(.cliproxy)))
        #expect(parsed("not a url") == .failure(.invalidURL(.cliproxy)))
    }

    @Test func credentialsInTheURLAreRefused() async throws {
        #expect(parsed("https://user:password@host.example") == .failure(.credentialsInURL(.cliproxy)))
        #expect(parsed("https://user@host.example") == .failure(.credentialsInURL(.cliproxy)))
        #expect(SetupFormError.credentialsInURL(.cliproxy).message.contains("Management key"))
        #expect(SetupFormError.credentialsInURL(.ocgo).message.contains("Client token"))

        let h = try await Harness().loaded()
        h.model.form.cliproxyURL = "https://user:password@host.example"
        await h.model.test(.cliproxy)
        await h.model.save()
        let message = SetupFormError.credentialsInURL(.cliproxy).message
        #expect(await h.calls.isEmpty)
        #expect(h.model.testState(.cliproxy) == .failed(message))
        #expect(h.model.saveState == .failed(message))
        #expect(h.store.load() == savedSettings)
        let raw = h.suite.defaults.data(forKey: SettingsStore.key).map { String(decoding: $0, as: UTF8.self) }
        #expect(raw?.contains("password") == false)
    }

    /// The coordinator clears its auth latch only for a Test of the saved config, so an
    /// untouched field must send the saved URL exactly, and Save must not rewrite it.
    @Test func untouchedSavedURLIsUsedExactly() async throws {
        let saved = URL(string: "https://cliproxy.example/")!
        var settings = savedSettings
        settings.cliproxyURL = saved
        let h = try await Harness(settings: settings).loaded()

        await h.model.test(.cliproxy)
        // Written differently but the same after normalizing: still the saved URL.
        h.model.form.cliproxyURL = "https://cliproxy.example/management.html"
        await h.model.test(.cliproxy)
        let config = SourceConfig(url: saved, secret: "old-key")
        #expect(await h.calls == [.test(.cliproxy, config), .test(.cliproxy, config)])

        h.model.form.menubarStyle = .compact
        await h.model.save()
        #expect(await h.calls == [.test(.cliproxy, config), .test(.cliproxy, config)])
        #expect(h.store.load()?.cliproxyURL?.absoluteString == "https://cliproxy.example/")

        // A different URL is still a change.
        h.model.form.cliproxyURL = "https://cliproxy.example/v2"
        await h.model.save()
        #expect(await h.calls.last == .configChanged(.cliproxy))
    }
}

@Suite("T9c Keychain failures")
@MainActor
struct T9cKeychainFailureTests {
    /// The cliproxy key is written, then the ocgo token write fails. The key stays
    /// written, the coordinator hears about it, and reverting to the old key writes it
    /// back instead of reading as unchanged.
    @Test func partialSaveMovesTheWrittenBaseline() async throws {
        let h = try await Harness().loaded()
        h.secrets.failWrites([.ocgoToken])
        h.model.form.cliproxyKey.value = "new-key"
        h.model.form.ocgoToken.value = "new-token"
        h.model.form.menubarStyle = .compact
        await h.model.save()
        guard case .failed(let message) = h.model.saveState else {
            Issue.record("expected a failed save, got \(h.model.saveState)")
            return
        }
        #expect(message.contains("ocgo-proxy"))
        #expect(h.secrets.stored[.cliproxyKey] == "new-key")
        #expect(h.secrets.stored[.ocgoToken] == "old-token")
        #expect(await h.calls == [.configChanged(.cliproxy)])
        #expect(h.store.load() == savedSettings)
        #expect(h.savedCallbacks.isEmpty)
        #expect(h.model.form.cliproxyKey.value == "new-key")

        h.secrets.failWrites([])
        h.model.form.cliproxyKey.value = "old-key"
        h.model.form.ocgoToken.value = "old-token"
        await h.model.save()
        #expect(h.model.saveState == .saved)
        #expect(h.secrets.stored[.cliproxyKey] == "old-key")
        #expect(h.secrets.stored[.ocgoToken] == "old-token")
        #expect(h.secrets.writes == ["write cliproxy-key", "write cliproxy-key"])
        #expect(await h.calls == [.configChanged(.cliproxy), .configChanged(.cliproxy)])
        #expect(h.store.load()?.menubarStyle == .compact)
    }

    /// Logs each configChanged with what UserDefaults and the Keychain hold for cliproxy
    /// at that moment, in the same log as the Keychain writes.
    private func logConfigChanged(_ h: Harness) async {
        let store = h.store
        let secrets = h.secrets
        await h.poll.observe { call in
            guard case .configChanged(let kind) = call else { return }
            let url = store.load()?.cliproxyURL?.absoluteString ?? "nil"
            secrets.note("configChanged \(kind) url=\(url) key=\(secrets.stored[.cliproxyKey] ?? "nil")")
        }
    }

    /// New URL and key, then the ocgo write fails: the new URL is saved with the new key
    /// before the coordinator hears of it, so the new key never goes to the old host.
    @Test func partialSaveStoresTheWrittenSourcesURL() async throws {
        let h = try await Harness().loaded()
        await logConfigChanged(h)
        h.secrets.failWrites([.ocgoToken])
        h.model.form.cliproxyURL = "http://100.64.0.2:8317"
        h.model.form.cliproxyKey.value = "new-key"
        h.model.form.ocgoToken.value = "new-token"
        h.model.form.menubarStyle = .compact
        h.model.form.staleMinutes = "10"
        await h.model.save()
        #expect(h.secrets.writes == ["write cliproxy-key",
                                     "configChanged cliproxy url=http://100.64.0.2:8317 key=new-key"])
        #expect(await h.calls == [.configChanged(.cliproxy)])
        // Only the cliproxy URL is saved; the style and threshold wait for a full save.
        var expected = savedSettings
        expected.cliproxyURL = URL(string: "http://100.64.0.2:8317")
        #expect(h.store.load() == expected)
        #expect(h.model.settings == expected)
        // The error says what was saved, so the user doesn't assume the old host stands.
        guard case .failed(let message) = h.model.saveState else {
            Issue.record("expected a failed save, got \(h.model.saveState)")
            return
        }
        #expect(message.contains("The cliproxy settings were saved"))

        // The retry saves the rest; cliproxy is already up to date.
        h.secrets.failWrites([])
        await h.model.save()
        #expect(h.model.saveState == .saved)
        var pool = savedSettings.pool
        pool.staleAfter = 600
        #expect(await h.calls == [.configChanged(.cliproxy), .configChanged(.ocgo), .poolSettingsChanged(pool)])
        #expect(h.secrets.stored[.ocgoToken] == "new-token")
        #expect(h.store.load()?.menubarStyle == .compact)
        #expect(h.store.load()?.cliproxyURL == URL(string: "http://100.64.0.2:8317"))
    }

    /// URL and key both cleared, then the ocgo write fails: cliproxy is saved as not
    /// configured before configChanged.
    @Test func partialSaveOfAClearedSource() async throws {
        let h = try await Harness().loaded()
        await logConfigChanged(h)
        h.secrets.failWrites([.ocgoToken])
        h.model.form.cliproxyURL = ""
        h.model.form.cliproxyKey.value = ""
        h.model.form.ocgoToken.value = "new-token"
        await h.model.save()
        #expect(h.secrets.writes == ["delete cliproxy-key", "configChanged cliproxy url=nil key=nil"])
        #expect(await h.calls == [.configChanged(.cliproxy)])
        var expected = savedSettings
        expected.cliproxyURL = nil
        #expect(h.store.load() == expected)

        h.secrets.failWrites([])
        await h.model.save()
        #expect(h.model.saveState == .saved)
        #expect(await h.calls == [.configChanged(.cliproxy), .configChanged(.ocgo)])
    }
}

@Suite("T9c Test validation errors")
@MainActor
struct T9cTestValidationTests {
    /// A Test stopped by a form error shows it only until the input changes.
    @Test func formErrorsClearWhenTheFieldsChange() async throws {
        let h = try await Harness(secrets: [:]).loaded()
        await h.model.test(.cliproxy)
        #expect(h.model.testState(.cliproxy) == .failed(SetupFormError.missingKey.message))
        h.model.form.cliproxyKey.value = "new-key"
        #expect(h.model.testState(.cliproxy) == .idle)
        h.model.form.cliproxyKey.value = ""
        #expect(h.model.testState(.cliproxy) == .failed(SetupFormError.missingKey.message))

        h.model.form.cliproxyURL = "https://user:password@host.example"
        await h.model.test(.cliproxy)
        #expect(h.model.testState(.cliproxy) == .failed(SetupFormError.credentialsInURL(.cliproxy).message))
        h.model.form.cliproxyURL = "https://host.example"
        #expect(h.model.testState(.cliproxy) == .idle)

        let saved = h.model.form.ocgoURL
        h.model.form.ocgoURL = ""
        await h.model.test(.ocgo)
        #expect(h.model.testState(.ocgo) == .failed(SetupFormError.missingURL(.ocgo).message))
        h.model.form.ocgoURL = saved
        #expect(h.model.testState(.ocgo) == .idle)
        #expect(await h.calls.isEmpty)
    }

    @Test func formErrorClearsAfterASuccessfulSave() async throws {
        let h = try await Harness(secrets: [:]).loaded()
        await h.model.test(.cliproxy)
        #expect(h.model.testState(.cliproxy) == .failed(SetupFormError.missingKey.message))
        h.model.form.cliproxyKey.value = "new-key"
        await h.model.save()
        #expect(h.model.saveState == .saved)
        #expect(h.model.testState(.cliproxy) == .idle)
    }

    /// Clearing the optional ocgo URL is an error for Test but a valid Save; after the
    /// Save the Test error goes even though the field still holds the same input.
    @Test func clearedOptionalURLTestErrorGoesAfterSave() async throws {
        let h = try await Harness().loaded()
        h.model.form.ocgoURL = ""
        h.model.form.ocgoToken.value = ""
        await h.model.test(.ocgo)
        #expect(h.model.testState(.ocgo) == .failed(SetupFormError.missingURL(.ocgo).message))
        await h.model.save()
        #expect(h.model.saveState == .saved)
        #expect(h.model.testState(.ocgo) == .idle)
    }
}

@Suite("T9c Overlapping loads and tests")
@MainActor
struct T9cOverlapTests {
    private func model(_ secrets: T9cFakeSecretStore, _ poll: any PollControl,
                       _ suite: T9cDefaults) throws -> SetupModel {
        let store = SettingsStore(defaults: suite.defaults)
        try store.save(savedSettings)
        return SetupModel(settings: savedSettings, saver: SettingsSaver(
            settingsStore: store, secrets: secrets, pollControl: poll))
    }

    @Test func olderLoadFinishingLateIsDropped() async throws {
        let suite = T9cDefaults()
        let secrets = T9cFakeSecretStore([.cliproxyKey: "old-key"])
        let m = try model(secrets, T9cFakePollControl(), suite)
        let gate = secrets.holdNextRead()
        let first = m.startLoad()
        try await t9cWait("first load reads") { gate.hasArrived }
        secrets.set("second-key", for: .cliproxyKey)
        await m.load()
        #expect(m.phase == .ready)
        #expect(m.form.cliproxyKey.value == "second-key")
        secrets.set("first-key", for: .cliproxyKey)
        gate.release()
        await first.value
        #expect(m.form.cliproxyKey.value == "second-key")
        #expect(m.phase == .ready)
    }

    @Test func loadFinishingAfterASaveIsDropped() async throws {
        let suite = T9cDefaults()
        let secrets = T9cFakeSecretStore([.cliproxyKey: "old-key"])
        let m = try model(secrets, T9cFakePollControl(), suite)
        let gate = secrets.holdNextRead()
        let first = m.startLoad()
        try await t9cWait("first load reads") { gate.hasArrived }
        await m.load()
        m.form.menubarStyle = .compact
        await m.save()
        #expect(m.saveState == .saved)
        secrets.set("stale-key", for: .cliproxyKey)
        gate.release()
        await first.value
        #expect(m.form.menubarStyle == .compact)
        #expect(m.form.cliproxyKey.value == "old-key")
        #expect(m.saveState == .saved)
    }

    @Test func startLoadResetsEditsAtOnce() async throws {
        let suite = T9cDefaults()
        let secrets = T9cFakeSecretStore([.cliproxyKey: "old-key"])
        let m = try model(secrets, T9cFakePollControl(), suite)
        await m.load()
        m.form.cliproxyURL = "http://edited:1"
        m.form.cliproxyKey.value = "unsaved"
        let gate = secrets.holdNextRead()
        let reload = m.startLoad()
        // Reset while the Keychain read is still blocked (a pending prompt).
        try await t9cWait("reload reads") { gate.hasArrived }
        #expect(m.phase == .loading)
        #expect(m.isBusy)
        #expect(m.form.cliproxyURL == cliproxyURL.absoluteString)
        #expect(m.form.cliproxyKey.value == "")
        gate.release()
        await reload.value
        #expect(m.phase == .ready)
        #expect(m.form.cliproxyKey.value == "old-key")
    }

    @Test func testWhileLoadingSendsNothing() async throws {
        let poll = T9cFakePollControl()
        let m = try model(T9cFakeSecretStore([.cliproxyKey: "old-key"]), poll, T9cDefaults())
        #expect(m.phase == .loading)
        await m.test(.cliproxy)
        #expect(await poll.calls.isEmpty)
        #expect(m.testState(.cliproxy) == .idle)
    }

    @Test func testResultAfterALoadIsDropped() async throws {
        let poll = T9cSuspendingPollControl()
        let m = try model(T9cFakeSecretStore([.cliproxyKey: "old-key"]), poll, T9cDefaults())
        await m.load()
        let test = Task { await m.test(.cliproxy) }
        try await t9cWait("test sent") { await poll.waiting == 1 }
        #expect(m.testState(.cliproxy) == .running)
        await m.load()
        await poll.finish(0, with: .success("3 credentials"))
        await test.value
        #expect(m.testState(.cliproxy) == .idle)
    }

    @Test func olderTestCannotOverwriteANewerOne() async throws {
        let poll = T9cSuspendingPollControl()
        let m = try model(T9cFakeSecretStore([.cliproxyKey: "old-key"]), poll, T9cDefaults())
        await m.load()
        let first = Task { await m.test(.cliproxy) }
        try await t9cWait("first test sent") { await poll.waiting == 1 }
        await m.load()
        let second = Task { await m.test(.cliproxy) }
        try await t9cWait("second test sent") { await poll.waiting == 2 }
        await poll.finish(1, with: .failure(.timeout))
        await second.value
        let timeoutText = SetupMessages.sentence(for: .timeout, kind: .cliproxy)
        #expect(m.testState(.cliproxy) == .failed(timeoutText))
        await poll.finish(0, with: .success("3 credentials"))
        await first.value
        #expect(m.testState(.cliproxy) == .failed(timeoutText))
    }

    /// An older success that lands after a newer 401 must not clear the rejection, or
    /// the next Test would skip the lockout confirmation.
    @Test func lateOlderSuccessKeepsANewerRejection() async throws {
        let poll = T9cSuspendingPollControl()
        let m = try model(T9cFakeSecretStore([.cliproxyKey: "old-key"]), poll, T9cDefaults())
        await m.load()
        let first = Task { await m.test(.cliproxy) }
        try await t9cWait("first test sent") { await poll.waiting == 1 }
        m.form.cliproxyKey.value = "new-key"
        let second = Task { await m.test(.cliproxy) }
        try await t9cWait("second test sent") { await poll.waiting == 2 }
        await poll.finish(1, with: .failure(.unauthorized))
        await second.value
        await poll.finish(0, with: .success("3 credentials"))
        await first.value
        #expect(m.cliproxyRejections == 1)
        #expect(m.confirmsTest(.cliproxy))
    }

    @Test func resultForEditedFieldsIsHidden() async throws {
        let poll = T9cSuspendingPollControl()
        let m = try model(T9cFakeSecretStore([.cliproxyKey: "old-key"]), poll, T9cDefaults())
        await m.load()
        // Edited while the request runs: the result never shows.
        let test = Task { await m.test(.cliproxy) }
        try await t9cWait("test sent") { await poll.waiting == 1 }
        m.form.cliproxyKey.value = "other-key"
        await poll.finish(0, with: .success("3 credentials"))
        await test.value
        #expect(m.testState(.cliproxy) == .idle)
        m.form.cliproxyKey.value = "old-key"
        #expect(m.testState(.cliproxy) == .idle)

        // Edited after the result shows: it hides, and shows again for the tested values.
        let again = Task { await m.test(.cliproxy) }
        try await t9cWait("second test sent") { await poll.waiting == 1 }
        await poll.finish(1, with: .success("3 credentials"))
        await again.value
        #expect(m.testState(.cliproxy) == .succeeded("Connected: 3 credentials"))
        m.form.cliproxyURL = "http://100.64.0.9:8317"
        #expect(m.testState(.cliproxy) == .idle)
        m.form.cliproxyURL = cliproxyURL.absoluteString
        #expect(m.testState(.cliproxy) == .succeeded("Connected: 3 credentials"))
        #expect(await poll.tested.count == 2)
    }
}

@Suite("T9c Settings window")
@MainActor
struct T9cWindowTests {
    /// The window outlives a close, so reopening must reload rather than show old edits.
    @Test func reopeningReloadsTheSavedValues() async throws {
        _ = NSApplication.shared
        let h = try Harness()
        let controller = SetupWindowController(model: h.model)
        controller.present()
        try await t9cWait("first load") { h.model.phase == .ready }
        h.model.form.cliproxyURL = "http://edited:1"
        h.model.form.cliproxyKey.value = "unsaved"
        // Presenting an open window keeps the edits.
        controller.present()
        #expect(h.model.form.cliproxyURL == "http://edited:1")
        controller.close()
        controller.present()
        try await t9cWait("reload") { h.model.phase == .ready }
        #expect(h.model.form.cliproxyURL == cliproxyURL.absoluteString)
        #expect(h.model.form.cliproxyKey.value == "old-key")
        controller.close()
    }

    /// A minimized window is still open: bringing it back keeps the unsaved edits.
    @Test func minimizedWindowKeepsItsEdits() async throws {
        _ = NSApplication.shared
        let h = try Harness()
        let controller = SetupWindowController(model: h.model)
        controller.present()
        try await t9cWait("first load") { h.model.phase == .ready }
        h.model.form.cliproxyURL = "http://edited:1"
        let window = try #require(controller.window)
        window.miniaturize(nil)
        try await t9cWait("minimized") { window.isMiniaturized }
        controller.present()
        #expect(h.model.phase == .ready)
        #expect(h.model.form.cliproxyURL == "http://edited:1")
        controller.close()
    }
}
