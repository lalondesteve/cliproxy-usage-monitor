import Foundation

/// Answers every request with the contents of one file and status 200. Lets the app
/// and tests run a real source against a fixture through the `HTTPTransport` seam.
public struct FileTransport: HTTPTransport {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = try Data(contentsOf: file)
        let url = r.url ?? file
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"])
        else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}
