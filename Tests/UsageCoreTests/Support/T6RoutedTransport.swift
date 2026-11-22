import Foundation
import UsageCore

/// Answers by URL path and records every request. Unknown paths get 404.
final class T6RoutedTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        let error: URLError?

        static func ok(_ body: Data) -> Reply { Reply(status: 200, body: body, error: nil) }
        static func status(_ code: Int, _ text: String = "") -> Reply {
            Reply(status: code, body: Data(text.utf8), error: nil)
        }
        static func fail(_ code: URLError.Code) -> Reply {
            Reply(status: 0, body: Data(), error: URLError(code))
        }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var routes: [String: Reply]
    private let clock: T6SteppingClock?

    /// With a clock, each request advances it by its step before the reply returns.
    init(_ routes: [String: Reply] = [:], clock: T6SteppingClock? = nil) {
        self.routes = routes
        self.clock = clock
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var paths: [String] { requests.map { $0.url?.path ?? "" } }

    func set(_ path: String, _ reply: Reply) {
        lock.withLock { routes[path] = reply }
    }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = lock.withLock { () -> Reply in
            _requests.append(r)
            return routes[r.url?.path ?? ""] ?? .status(404, "404 page not found")
        }
        clock?.step()
        if let error = reply.error { throw error }
        return (reply.body,
                HTTPURLResponse(url: r.url!, statusCode: reply.status, httpVersion: nil,
                                headerFields: nil)!)
    }
}

/// A clock that moves forward only when `step()` is called.
final class T6SteppingClock: NowProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    let stepBy: TimeInterval

    init(_ start: Date, stepBy: TimeInterval) {
        current = start
        self.stepBy = stepBy
    }

    var now: Date { lock.withLock { current } }
    func step() { lock.withLock { current += stepBy } }
}

enum T6Paths {
    static let credentials = "/v8/management/credentials"
    static let strategy = "/v0/management/routing/strategy"
    static let config = "/v0/management/config"
    static let history = "/v8/management/quota/history"
}
