import Foundation
import UsageCore

/// What the Keychain held when the form opened.
enum SecretBaseline: Equatable, Sendable {
    /// nil: no item.
    case loaded(String?)
    /// The read failed (prompt denied, or another Keychain error). The stored item, if
    /// any, is left alone unless the user types a new value.
    case unreadable(String)
}

/// What saving does to one secret.
enum SecretEdit: Equatable, Sendable {
    case unchanged
    case set(String)
    case cleared
}

/// A secret text field and the value it started from.
struct SecretField: Equatable, Sendable {
    var value: String
    var baseline: SecretBaseline

    init(baseline: SecretBaseline) {
        self.baseline = baseline
        if case .loaded(let stored?) = baseline { value = stored } else { value = "" }
    }

    /// Trimmed; nil when empty.
    var entered: String? { SetupForm.trimmedOrNil(value) }

    var edit: SecretEdit {
        switch baseline {
        case .loaded(let stored):
            guard let entered else { return stored == nil ? .unchanged : .cleared }
            return entered == stored ? .unchanged : .set(entered)
        case .unreadable:
            return entered.map { .set($0) } ?? .unchanged
        }
    }
}

struct AliasRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var fileKey: String
    var identity: String

    init(id: UUID = UUID(), fileKey: String = "", identity: String = "") {
        self.id = id
        self.fileKey = fileKey
        self.identity = identity
    }
}

enum SetupFormError: Error, Equatable, Sendable {
    case invalidURL(SourceKind)
    case credentialsInURL(SourceKind)
    case missingURL(SourceKind)
    case missingKey
    case invalidStaleMinutes
    case incompleteAlias(row: Int)
    case duplicateAlias(String)

    var message: String {
        switch self {
        case .invalidURL(let kind):
            "The \(SetupForm.name(kind)) URL isn't valid: use http:// or https:// with a host."
        case .credentialsInURL(let kind):
            "Don't include credentials in the \(SetupForm.name(kind)) URL (URLs are saved in plain text). Use the \(kind == .cliproxy ? "Management key" : "Client token") field instead."
        case .missingURL(let kind):
            "Enter the \(SetupForm.name(kind)) URL first."
        case .missingKey:
            "Enter the cliproxy management key first."
        case .invalidStaleMinutes:
            "Stale after must be a whole number from 1 to \(SetupForm.maxStaleMinutes) minutes."
        case .incompleteAlias(let row):
            "Alias row \(row) needs both a credential filename and a target account."
        case .duplicateAlias(let fileKey):
            "The credential file \(fileKey) is listed more than once."
        }
    }
}

/// What a valid form saves.
struct SaveRequest: Equatable, Sendable {
    var settings: AppSettings
    var cliproxyKey: SecretEdit
    var ocgoToken: SecretEdit
}

/// The Settings form's values, as typed. Pure: no I/O. `SetupModel` owns one and the
/// view binds to it.
struct SetupForm: Equatable, Sendable {
    static let maxStaleMinutes = 7 * 24 * 60

    var cliproxyURL: String
    var cliproxyKey: SecretField
    var ocgoURL: String
    var ocgoToken: SecretField
    var menubarStyle: MenubarStyle
    var staleMinutes: String
    var aliases: [AliasRow]
    /// The URLs the form opened with. A field that normalizes to the same URL keeps the
    /// saved one exactly, so Test matches the saved config (the coordinator's auth latch
    /// compares them) and an unrelated Save doesn't rewrite it.
    private var savedURLs: [SourceKind: URL]

    /// After a partial save stored a source's URL; the field keeps what the user typed.
    mutating func setSavedURL(_ url: URL?, for kind: SourceKind) {
        savedURLs[kind] = url
    }

    init(settings: AppSettings, cliproxyKey: SecretBaseline, ocgoToken: SecretBaseline) {
        var saved: [SourceKind: URL] = [:]
        saved[.cliproxy] = settings.cliproxyURL
        saved[.ocgo] = settings.ocgoURL
        savedURLs = saved
        cliproxyURL = settings.cliproxyURL?.absoluteString ?? ""
        self.cliproxyKey = SecretField(baseline: cliproxyKey)
        ocgoURL = settings.ocgoURL?.absoluteString ?? ""
        self.ocgoToken = SecretField(baseline: ocgoToken)
        menubarStyle = settings.menubarStyle
        let minutes = settings.pool.staleAfter / 60
        staleMinutes = minutes == minutes.rounded() ? String(Int(minutes)) : String(minutes)
        aliases = settings.pool.identityAliases
            .sorted { $0.key < $1.key }
            .map { AliasRow(fileKey: $0.key, identity: $0.value) }
    }

    /// ocgo is optional: an empty URL means it isn't configured and the Go row is hidden.
    var ocgoConfigured: Bool { Self.trimmedOrNil(ocgoURL) != nil }

    /// The values the Test button sends. A Test needs a URL, and for cliproxy a key: a
    /// request without one would only count as a failed attempt toward the IP ban.
    func sourceConfig(_ kind: SourceKind) -> Result<SourceConfig, SetupFormError> {
        let secret = kind == .cliproxy ? cliproxyKey.entered : ocgoToken.entered
        switch resolvedURL(kind) {
        case .failure(let e): return .failure(e)
        case .success(nil): return .failure(.missingURL(kind))
        case .success(let url?):
            if kind == .cliproxy, secret == nil { return .failure(.missingKey) }
            return .success(SourceConfig(url: url, secret: secret))
        }
    }

    /// The settings to save. Fields the form doesn't show (`activeCallsEnabled`) come
    /// from `base`.
    func saveRequest(base: AppSettings) -> Result<SaveRequest, SetupFormError> {
        do throws(SetupFormError) {
            var settings = base
            settings.cliproxyURL = try resolvedURL(.cliproxy).get()
            settings.ocgoURL = try resolvedURL(.ocgo).get()
            settings.menubarStyle = menubarStyle
            settings.pool.staleAfter = try staleAfter().get()
            settings.pool.identityAliases = try identityAliases().get()
            // A configured cliproxy needs a key. An unreadable Keychain item may still
            // hold one, so only a known-empty field is refused.
            if settings.cliproxyURL != nil, cliproxyKey.entered == nil,
               case .loaded = cliproxyKey.baseline {
                throw SetupFormError.missingKey
            }
            return .success(SaveRequest(settings: settings, cliproxyKey: cliproxyKey.edit,
                                        ocgoToken: ocgoToken.edit))
        } catch {
            return .failure(error)
        }
    }

    private func staleAfter() -> Result<TimeInterval, SetupFormError> {
        guard let minutes = Int(staleMinutes.trimmingCharacters(in: .whitespaces)),
              (1...Self.maxStaleMinutes).contains(minutes) else {
            return .failure(.invalidStaleMinutes)
        }
        return .success(TimeInterval(minutes * 60))
    }

    /// Blank rows are dropped; a half-filled row or a repeated file is an error.
    private func identityAliases() -> Result<[String: String], SetupFormError> {
        var result: [String: String] = [:]
        for (index, row) in aliases.enumerated() {
            let fileKey = Self.trimmedOrNil(row.fileKey)
            let identity = Self.trimmedOrNil(row.identity)
            switch (fileKey, identity) {
            case (nil, nil): continue
            case (let fileKey?, let identity?):
                guard result[fileKey] == nil else { return .failure(.duplicateAlias(fileKey)) }
                result[fileKey] = identity
            default:
                return .failure(.incompleteAlias(row: index + 1))
            }
        }
        return .success(result)
    }

    /// The field's URL, or the saved URL unchanged when the field normalizes to it.
    func resolvedURL(_ kind: SourceKind) -> Result<URL?, SetupFormError> {
        let parsed = Self.parseURL(kind == .cliproxy ? cliproxyURL : ocgoURL, kind: kind)
        if case .success(let url?) = parsed, let saved = savedURLs[kind],
           case .success(url?) = Self.parseURL(saved.absoluteString, kind: kind) {
            return .success(saved)
        }
        return parsed
    }

    /// nil for an empty field. Accepts cliproxy's management page URL as pasted from the
    /// browser, as T3 does: drops the query and fragment, trailing slashes and a
    /// `/management.html` path suffix (any case). Refuses a user name or password, which
    /// would otherwise be saved in plain text.
    static func parseURL(_ text: String, kind: SourceKind) -> Result<URL?, SetupFormError> {
        guard let trimmed = trimmedOrNil(text) else { return .success(nil) }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            return .failure(.invalidURL(kind))
        }
        if components.user != nil || components.password != nil {
            return .failure(.credentialsInURL(kind))
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let page = "/management.html"
        if path.lowercased().hasSuffix(page) { path.removeLast(page.count) }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else { return .failure(.invalidURL(kind)) }
        return .success(url)
    }

    static func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func name(_ kind: SourceKind) -> String {
        switch kind {
        case .cliproxy: "cliproxy"
        case .ocgo: "ocgo-proxy"
        }
    }
}
