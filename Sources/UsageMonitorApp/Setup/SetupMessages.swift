import Foundation
import UsageCore

/// Test results in words, one sentence per `SourceError` case. Only a 401 depends on the
/// source: cliproxy's ban after five bad keys doesn't apply to ocgo-proxy.
enum SetupMessages {
    static func sentence(for error: SourceError, kind: SourceKind) -> String {
        switch error {
        case .unauthorized:
            switch kind {
            case .cliproxy:
                "cliproxy refused the request: wrong management key, or a URL whose management paths are blocked. Check both before retrying: 5 failed attempts ban this Mac's IP for 30 minutes."
            case .ocgo:
                "Wrong client token. Check the token and try again."
            }
        case .remoteManagementDisabled:
            "Remote management is disabled on cliproxy. Set remote-management.allow-remote to true (block the management paths at the public ingress first), then try again."
        case .ipBanned:
            "cliproxy banned this Mac's IP after 5 failed attempts. Wait 30 minutes before retrying."
        case .tlsUntrusted:
            "Untrusted TLS certificate. Add the server's CA to Keychain Access and set it to Always Trust."
        case .timeout:
            "Request timed out. Check your NetBird connection, URL and port."
        case .unreachable:
            "Couldn't reach the server. Check the URL and your NetBird connection."
        case .http(let code):
            "Server returned HTTP \(code). Check that the URL points to the proxy."
        case .decoding(let detail):
            "Unexpected response (\(detail)). Check that the URL points to the right proxy."
        }
    }

    static func result(_ result: Result<String, SourceError>, kind: SourceKind) -> String {
        switch result {
        case .success(let summary): "Connected: \(summary)"
        case .failure(let error): sentence(for: error, kind: kind)
        }
    }
}
