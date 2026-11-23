import Foundation

// Settings: T9c edits, T3 and T9a read. Secrets live in the Keychain, not here.

public enum MenubarStyle: String, Codable, CaseIterable, Sendable {
    case normal, compact
}

public struct PoolSettings: Codable, Equatable, Sendable {
    public var staleAfter: TimeInterval = 1800
    /// fileKey -> canonical identity
    public var identityAliases: [String: String] = [:]

    public init(staleAfter: TimeInterval = 1800, identityAliases: [String: String] = [:]) {
        self.staleAfter = staleAfter
        self.identityAliases = identityAliases
    }

    // Missing keys take the defaults, so settings saved by an older build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PoolSettings()
        staleAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .staleAfter) ?? d.staleAfter
        identityAliases = try c.decodeIfPresent([String: String].self, forKey: .identityAliases)
            ?? d.identityAliases
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var cliproxyURL: URL?
    public var ocgoURL: URL?
    public var menubarStyle: MenubarStyle = .normal
    public var pool = PoolSettings()
    public var activeCallsEnabled = false

    public init(cliproxyURL: URL? = nil, ocgoURL: URL? = nil, menubarStyle: MenubarStyle = .normal,
                pool: PoolSettings = PoolSettings(), activeCallsEnabled: Bool = false) {
        self.cliproxyURL = cliproxyURL
        self.ocgoURL = ocgoURL
        self.menubarStyle = menubarStyle
        self.pool = pool
        self.activeCallsEnabled = activeCallsEnabled
    }

    // Missing keys take the defaults, so settings saved by an older build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        cliproxyURL = try c.decodeIfPresent(URL.self, forKey: .cliproxyURL)
        ocgoURL = try c.decodeIfPresent(URL.self, forKey: .ocgoURL)
        menubarStyle = try c.decodeIfPresent(MenubarStyle.self, forKey: .menubarStyle) ?? d.menubarStyle
        pool = try c.decodeIfPresent(PoolSettings.self, forKey: .pool) ?? d.pool
        activeCallsEnabled = try c.decodeIfPresent(Bool.self, forKey: .activeCallsEnabled)
            ?? d.activeCallsEnabled
    }
}
