import Foundation
import Observation
import UsageCore

/// State behind the Settings window. The view binds to `form`; Test and Save go through
/// here. Keychain reads run off the main thread, so a pending access prompt never
/// freezes the app; the form stays disabled until they finish.
///
/// Loads, saves and Tests can overlap (a slow Keychain read, a slow server), so each
/// takes a generation number and a result applies only if nothing newer started.
@MainActor @Observable
final class SetupModel {
    enum Phase: Equatable { case loading, ready }

    enum TestState: Equatable {
        case idle, running
        case succeeded(String), failed(String)
    }

    enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    /// A Test's state and the form input it ran on: the config it sent, or the form
    /// error that stopped it.
    private struct TestRecord {
        var state: TestState
        var input: Result<SourceConfig, SetupFormError>
    }

    private(set) var phase: Phase = .loading
    var form: SetupForm
    private var tests: [SourceKind: TestRecord] = [:]
    private(set) var saveState: SaveState = .idle
    /// The last saved settings.
    private(set) var settings: AppSettings

    /// Called after each successful save, so the integrator can apply the menubar style
    /// and hide or show the Go row (`AppSettings.ocgoConfigured`).
    var onSaved: ((AppSettings, SettingsChanges) -> Void)?
    /// Called when the menubar style changes. The style applies and is stored at once,
    /// without Save.
    var onMenubarStyle: ((MenubarStyle) -> Void)?

    private let saver: SettingsSaver
    /// Bumped by each load and each save; a load result applies only if it still matches.
    private var formGeneration = 0
    /// Bumped per source by each Test and by each load.
    private var testGenerations: [SourceKind: Int] = [:]
    /// Keys cliproxy rejected (401) on Test since its last successful Test. cliproxy bans
    /// this Mac's IP after 5, so the next Test asks first. Survives reopening the window,
    /// since the ban counts on the server.
    private(set) var cliproxyRejections = 0
    /// The Test generation of the newest counted rejection. A success clears the count
    /// only if its Test was sent after that one.
    private var newestRejection = 0

    init(settings: AppSettings, saver: SettingsSaver) {
        self.settings = settings
        self.saver = saver
        form = SetupForm(settings: settings, cliproxyKey: .loaded(nil), ocgoToken: .loaded(nil))
    }

    var isBusy: Bool { phase == .loading || saveState == .saving }

    /// Stores the style on top of the last saved settings (other unsaved edits stay in
    /// the form) and applies it.
    func setMenubarStyle(_ style: MenubarStyle) {
        form.menubarStyle = style
        guard style != settings.menubarStyle else { return }
        var updated = settings
        updated.menubarStyle = style
        do {
            try saver.settingsStore.save(updated)
            settings = updated
        } catch {
            saveState = .failed("Couldn't save the menubar style: \(error).")
        }
        onMenubarStyle?(style)
    }

    /// The Test button asks before sending when cliproxy already rejected a key.
    func confirmsTest(_ kind: SourceKind) -> Bool {
        kind == .cliproxy && cliproxyRejections > 0
    }

    /// A Test result, or the form error that stopped a Test, shows only while the form
    /// still holds the same input.
    func testState(_ kind: SourceKind) -> TestState {
        guard let record = tests[kind], form.sourceConfig(kind) == record.input else { return .idle }
        return record.state
    }

    /// Resets the form to the saved values and reads both secrets. The window controller
    /// calls this each time the window opens. The reset happens before this returns, so
    /// the window never shows stale edits; the Keychain read finishes in the task.
    @discardableResult
    func startLoad() -> Task<Void, Never> {
        guard saveState != .saving else { return Task {} }
        formGeneration += 1
        let generation = formGeneration
        phase = .loading
        // Placeholder until the Keychain answers, which may take as long as a prompt.
        form = SetupForm(settings: settings, cliproxyKey: .loaded(nil), ocgoToken: .loaded(nil))
        tests = [:]
        for kind in SourceKind.allCases { testGenerations[kind, default: 0] += 1 }
        saveState = .idle
        let secrets = saver.secrets
        return Task {
            let (key, token) = await Task.detached {
                (Self.baseline(secrets, .cliproxyKey), Self.baseline(secrets, .ocgoToken))
            }.value
            guard generation == formGeneration else { return }
            form = SetupForm(settings: settings, cliproxyKey: key, ocgoToken: token)
            phase = .ready
        }
    }

    func load() async { await startLoad().value }

    /// One request with the form's values. The button is disabled while it runs, so a
    /// Test is never sent twice by a double click.
    func test(_ kind: SourceKind) async {
        guard phase == .ready, testState(kind) != .running else { return }
        testGenerations[kind, default: 0] += 1
        let generation = testGenerations[kind]
        let input = form.sourceConfig(kind)
        switch input {
        case .failure(let error):
            tests[kind] = TestRecord(state: .failed(error.message), input: input)
        case .success(let config):
            tests[kind] = TestRecord(state: .running, input: input)
            let result = await saver.pollControl.test(kind, config)
            // The request reached the server, so a rejection counts even if the form
            // moved on. A success clears the count only if it was sent after the newest
            // rejection: an older success arriving late must not erase a newer one.
            if kind == .cliproxy, let sent = generation {
                switch result {
                case .success: if sent > newestRejection { cliproxyRejections = 0 }
                case .failure(.unauthorized):
                    cliproxyRejections += 1
                    newestRejection = max(newestRejection, sent)
                case .failure: break
                }
            }
            guard generation == testGenerations[kind] else { return }
            guard form.sourceConfig(kind) == input else {
                tests[kind] = nil
                return
            }
            let text = SetupMessages.result(result, kind: kind)
            tests[kind] = TestRecord(state: result.isSuccess ? .succeeded(text) : .failed(text), input: input)
        }
    }

    func save() async {
        guard phase == .ready, saveState != .saving else { return }
        let request: SaveRequest
        switch form.saveRequest(base: settings) {
        case .failure(let error):
            saveState = .failed(error.message)
            return
        case .success(let r):
            request = r
        }
        formGeneration += 1
        saveState = .saving
        do {
            let changes = try await saver.save(request, replacing: settings)
            settings = request.settings
            form = SetupForm(settings: request.settings,
                             cliproxyKey: Self.baseline(after: request.cliproxyKey, form.cliproxyKey.baseline),
                             ocgoToken: Self.baseline(after: request.ocgoToken, form.ocgoToken.baseline))
            // A form error from Test (a cleared optional URL, say) is now the saved state.
            tests = tests.filter { _, record in
                if case .failure = record.input { return false } else { return true }
            }
            saveState = .saved
            onSaved?(request.settings, changes)
        } catch let error as KeychainSaveError {
            // Secrets written before the failure are in the Keychain now, with their
            // source's URL in UserDefaults, so the next Save compares against them; the
            // typed values stay in the fields.
            settings = error.saved
            for (kind, edit) in error.committed {
                switch kind {
                case .cliproxy:
                    form.cliproxyKey.baseline = Self.baseline(after: edit, form.cliproxyKey.baseline)
                    form.setSavedURL(error.saved.cliproxyURL, for: .cliproxy)
                case .ocgo:
                    form.ocgoToken.baseline = Self.baseline(after: edit, form.ocgoToken.baseline)
                    form.setSavedURL(error.saved.ocgoURL, for: .ocgo)
                }
            }
            saveState = .failed("Couldn't save: \(error).")
        } catch {
            saveState = .failed("Couldn't save: \(error).")
        }
    }

    private nonisolated static func baseline(_ store: any SecretStore,
                                             _ account: Keychain.Account) -> SecretBaseline {
        do { return .loaded(try store.read(account)) } catch { return .unreadable("\(error)") }
    }

    private static func baseline(after edit: SecretEdit, _ old: SecretBaseline) -> SecretBaseline {
        switch edit {
        case .unchanged: old
        case .set(let value): .loaded(value)
        case .cleared: .loaded(nil)
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }
}
