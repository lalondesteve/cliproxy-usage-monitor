import Foundation
import UsageCore

/// Answers with a fixed status and body and records every request.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let status: Int
    let body: Data
    let error: URLError?

    init(status: Int = 200, body: Data = Data(), error: URLError? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(r) }
        if let error { throw error }
        return (body, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
