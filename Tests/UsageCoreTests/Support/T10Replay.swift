import Foundation
import UsageCore

/// Serves a capture folder (the layout `scripts/capture-fixtures.sh` writes) by URL
/// path, ignoring host and query; 404 for anything else. Records request paths.
final class T10FolderTransport: HTTPTransport, @unchecked Sendable {
    static let files = [
        "/v8/management/credentials": "cliproxy-credentials.json",
        "/v8/management/quota/history": "cliproxy-quota-history-24h.json",
        "/v0/management/routing/strategy": "cliproxy-routing-strategy.json",
        "/v0/management/config": "cliproxy-config-routing.json",
        "/_ocgo/status": "ocgo-status.json",
    ]

    let folder: URL
    private let lock = NSLock()
    private var _paths: [String] = []

    init(folder: URL) {
        self.folder = folder
    }

    var paths: [String] { lock.withLock { _paths } }

    func file(_ path: String) -> URL? {
        guard let name = Self.files[path] else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = r.url!
        lock.withLock { _paths.append(url.path) }
        let (status, body): (Int, Data)
        if let file = file(url.path) {
            (status, body) = (200, try Data(contentsOf: file))
        } else {
            (status, body) = (404, Data("404 page not found".utf8))
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// The real pipeline on a temporary SQLite file: `CliproxySource`, the fork history
/// source and `OcgoSource` over `transport`, `Ledger`, `PollCoordinator` and
/// `PoolEngine`. The same factories as the app's `Wiring.pollSetup`.
struct T10Pipeline {
    let coordinator: PollCoordinator
    let database: T5TempDatabase

    init(transport: any HTTPTransport, clock: any NowProvider, settings: PoolSettings = PoolSettings(),
         configured: Set<SourceKind> = Set(SourceKind.allCases)) throws {
        database = T5TempDatabase()
        let store = try SQLiteHistoryStore(path: database.path, now: clock)
        let configs: [SourceKind: SourceConfig] = [
            .cliproxy: SourceConfig(url: URL(string: "http://cliproxy.test:8317")!, secret: "key"),
            .ocgo: SourceConfig(url: URL(string: "http://ocgo.test:8320")!, secret: "token"),
        ].filter { configured.contains($0.key) }
        let setup = PollSetup(
            savedConfig: { configs[$0] },
            makeSource: { kind, config in
                switch kind {
                case .cliproxy: CliproxySource(config: config, transport: transport, now: clock)
                case .ocgo: OcgoSource(config: config, transport: transport, now: clock)
                }
            },
            makeForkSource: { CliproxyForkHistorySource(config: $0, transport: transport) })
        coordinator = PollCoordinator(setup: setup, ledger: Ledger(store: store, settings: settings),
                                      store: store, settings: settings, clock: clock,
                                      scheduler: T8BlockingScheduler())
    }
}
