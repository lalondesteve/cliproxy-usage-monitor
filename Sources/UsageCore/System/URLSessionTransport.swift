import Foundation

/// `HTTPTransport` over an ephemeral URLSession: no cookies, no cache, no stored
/// credentials. URLSession never retries a Bearer 401 on its own, and redirects are
/// refused: a 3xx comes back to the caller as the response, so one `send` is exactly
/// one request and the secret never reaches a redirect target.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let delegate = NoRedirectDelegate()

    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: r, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Declines every redirect, so URLSession completes with the original 3xx response.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension SourceError {
    /// Maps a transport failure (what `HTTPTransport.send` throws) to a `SourceError`.
    public static func transport(_ error: Error) -> SourceError {
        guard let e = error as? URLError else { return .unreachable }
        switch e.code {
        case .timedOut:
            return .timeout
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .secureConnectionFailed:
            return .tlsUntrusted
        default:
            return .unreachable
        }
    }
}
