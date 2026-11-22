import Foundation
import UsageCore

/// The `PollControl` calls one save needs.
struct SettingsChanges: Equatable, Sendable {
    /// Sources whose URL or secret changed, in `SourceKind.allCases` order.
    var configChanged: [SourceKind] = []
    /// Set when the stale threshold or the alias list changed.
    var poolSettings: PoolSettings?

    var isEmpty: Bool { configChanged.isEmpty && poolSettings == nil }
}

enum SettingsDiff {
    /// Pure. A menubar style change alone needs no `PollControl` call.
    static func changes(from old: AppSettings, to request: SaveRequest) -> SettingsChanges {
        let new = request.settings
        var changes = SettingsChanges()
        for kind in SourceKind.allCases {
            let urlChanged: Bool
            let secret: SecretEdit
            switch kind {
            case .cliproxy: (urlChanged, secret) = (old.cliproxyURL != new.cliproxyURL, request.cliproxyKey)
            case .ocgo: (urlChanged, secret) = (old.ocgoURL != new.ocgoURL, request.ocgoToken)
            }
            if urlChanged || secret != .unchanged { changes.configChanged.append(kind) }
        }
        if old.pool != new.pool { changes.poolSettings = new.pool }
        return changes
    }
}

/// A Keychain write failed. Secrets written before it stay written (a rollback could
/// fail too); `committed` lists them so the form can move its baselines. `saved` is what
/// UserDefaults holds now: the old settings with the URL of each committed source taken
/// from the request, so a new key is never paired with the old host. The coordinator
/// has already been told about the committed sources.
struct KeychainSaveError: Error, Equatable, CustomStringConvertible {
    let committed: [SourceKind: SecretEdit]
    let saved: AppSettings
    let failed: SourceKind
    let reason: String

    var description: String {
        let failure = "the \(SetupForm.name(failed)) secret couldn't be written to the Keychain (\(reason))"
        let saved = SourceKind.allCases.filter { committed[$0] != nil }.map(SetupForm.name)
        return saved.isEmpty ? failure
            : "\(failure). The \(saved.joined(separator: " and ")) settings were saved"
    }
}

/// Saves the form: secrets to the `SecretStore`, the rest to UserDefaults, then tells the
/// coordinator what changed. Settings never calls a source directly.
struct SettingsSaver: Sendable {
    let settingsStore: SettingsStore
    let secrets: any SecretStore
    let pollControl: any PollControl

    /// Writes the Keychain first, then UserDefaults, then calls `PollControl`. Keychain
    /// calls run off the caller's thread, since a pending access prompt blocks them.
    ///
    /// If a secret write fails after another succeeded, the written source's URL is
    /// saved with it (nothing else from the request), and only then does `PollControl`
    /// hear `configChanged` for that source.
    func save(_ request: SaveRequest, replacing old: AppSettings) async throws -> SettingsChanges {
        let changes = SettingsDiff.changes(from: old, to: request)
        let secrets = self.secrets
        let edits: [(SourceKind, SecretEdit)] = [(.cliproxy, request.cliproxyKey), (.ocgo, request.ocgoToken)]
        let (committed, failure) = await Task.detached { () -> ([SourceKind: SecretEdit], (SourceKind, String)?) in
            var committed: [SourceKind: SecretEdit] = [:]
            for (kind, edit) in edits {
                let account = Keychain.Account.secret(for: kind)
                do {
                    switch edit {
                    case .unchanged: continue
                    case .set(let value): try secrets.write(value, for: account)
                    case .cleared: try secrets.delete(account)
                    }
                } catch {
                    return (committed, (kind, "\(error)"))
                }
                committed[kind] = edit
            }
            return (committed, nil)
        }.value
        if let (failed, reason) = failure {
            var partial = old
            if committed[.cliproxy] != nil { partial.cliproxyURL = request.settings.cliproxyURL }
            if committed[.ocgo] != nil { partial.ocgoURL = request.settings.ocgoURL }
            if partial != old { try settingsStore.save(partial) }
            for kind in SourceKind.allCases where committed[kind] != nil {
                await pollControl.configChanged(kind)
            }
            throw KeychainSaveError(committed: committed, saved: partial, failed: failed, reason: reason)
        }
        try settingsStore.save(request.settings)
        for kind in changes.configChanged {
            await pollControl.configChanged(kind)
        }
        if let pool = changes.poolSettings {
            await pollControl.poolSettingsChanged(pool)
        }
        return changes
    }
}
