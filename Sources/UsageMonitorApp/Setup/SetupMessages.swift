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
                "cliproxy rejected the management key (401); check it before testing again, because cliproxy bans this Mac's IP for 30 minutes after 5 failed attempts."
            case .ocgo:
                "ocgo-proxy rejected the client token (401); check the token and test again."
            }
        case .remoteManagementDisabled:
            "cliproxy has remote management turned off; set remote-management.allow-remote to true in its config (block the management paths at the public ingress first) and test again."
        case .ipBanned:
            "cliproxy has banned this Mac's IP after 5 failed attempts; wait 30 minutes before testing again."
        case .tlsUntrusted:
            "The server's TLS certificate isn't trusted; add its private CA to the macOS Keychain and set it to Always Trust."
        case .timeout:
            "The server didn't answer in time; check that this Mac is connected to NetBird and that the address and port are right."
        case .unreachable:
            "The server couldn't be reached; check the URL and that this Mac can reach it over NetBird."
        case .http(let code):
            "The server answered with HTTP \(code); check that the URL is the proxy's base address."
        case .decoding(let detail):
            "The server answered, but not with the data the app expects (\(detail)); check that the URL points at the right proxy."
        }
    }

    static func result(_ result: Result<String, SourceError>, kind: SourceKind) -> String {
        switch result {
        case .success(let summary): "Connected: \(summary)"
        case .failure(let error): sentence(for: error, kind: kind)
        }
    }
}
