import Foundation
import UsageCore

/// Composition root (integrator). T1: one ocgo source, the tracer ledger and pool.
enum Wiring {
    struct OcgoSetup {
        let source: any UsageSource
        let description: String
    }

    enum SetupError: Error, CustomStringConvertible {
        case noToken(URL)
        case noFixture
        var description: String {
            switch self {
            case .noToken(let url): "no ocgo token in the Keychain for \(url.absoluteString)"
            case .noFixture: "bundled fixture not found"
            }
        }
    }

    /// Live proxy when `--ocgo-url` is given and a token exists; otherwise a fixture.
    static func ocgoSource(options: LaunchOptions, token: String?) -> Result<OcgoSetup, SetupError> {
        let clock = SystemNowProvider()
        if let url = options.ocgoURL {
            guard let token, !token.isEmpty else { return .failure(.noToken(url)) }
            let source = OcgoSource(config: SourceConfig(url: url, secret: token),
                                    transport: URLSessionTransport(), now: clock)
            return .success(OcgoSetup(source: source, description: url.absoluteString))
        }
        guard let file = options.ocgoFixture ?? bundledFixture() else { return .failure(.noFixture) }
        let source = OcgoSource(config: SourceConfig(url: URL(string: "http://fixture.invalid")!, secret: nil),
                                transport: FileTransport(file: file), now: clock)
        return .success(OcgoSetup(source: source, description: "fixture \(file.lastPathComponent)"))
    }

    static func bundledFixture() -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "ocgo-status", withExtension: "json", subdirectory: "fixtures"),
            URL(fileURLWithPath: "Tests/UsageCoreTests/Fixtures/synthetic/T1/ocgo-status.json"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One poll: source -> LedgerView -> dashboard.
    static func poll(_ source: any UsageSource, now: Date = Date()) async -> Result<DashboardModel, SourceError> {
        await source.fetch(since: nil).map { snapshot in
            TracerPool.dashboard(
                TracerLedger(snapshot: snapshot),
                PoolSettings(),
                [.ocgo: .ok(at: snapshot.takenAt), .cliproxy: .notConfigured],
                now
            )
        }
    }
}
