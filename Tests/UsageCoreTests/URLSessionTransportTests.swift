import Foundation
import Network
import Testing
import UsageCore

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
    @Test func refusesRedirects() async throws {
        let server = try await LoopbackServer.start(response:
            "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/_ocgo/status")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSessionTransport(timeout: 5).send(request)

        #expect(response.statusCode == 302)
        #expect(response.url?.path == "/_ocgo/status")
        // Give a follow-up request (if one were sent) time to arrive.
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.requestLines == ["GET /_ocgo/status HTTP/1.1"])
    }
}

/// A one-response HTTP server on 127.0.0.1 that records each request line.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var _requestLines: [String] = []

    var requestLines: [String] { lock.withLock { _requestLines } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init(response: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        self.response = Data(response.utf8)
    }

    static func start(response: String) async throws -> LoopbackServer {
        let server = try LoopbackServer(response: response)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { c.resume() }
                case .failed(let e): if once.claim() { c.resume(throwing: e) }
                default: break
                }
            }
            server.listener.newConnectionHandler = { [weak server] conn in server?.serve(conn) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = text.components(separatedBy: "\r\n").first ?? ""
            self.lock.withLock { self._requestLines.append(line) }
            conn.send(content: self.response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
