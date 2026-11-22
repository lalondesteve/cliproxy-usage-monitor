import Foundation

/// Command-line options. Unknown arguments (such as the ones macOS adds when it
/// launches an app) are ignored.
struct LaunchOptions: Equatable {
    /// Live ocgo-proxy base URL; needs a token in the Keychain.
    var ocgoURL: URL?
    /// A `/_ocgo/status` body to read instead of the bundled synthetic fixture.
    var ocgoFixture: URL?
    /// Writes the debug test token (its own Keychain account, not the ocgo token)
    /// through the same code as the debug menu entry.
    var debugWriteTestToken = false
    /// Writes a PNG of the status item button here after the first poll.
    var debugSnapshot: URL?

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--ocgo-url":
                options.ocgoURL = it.next().flatMap { URL(string: $0) }
            case "--ocgo-fixture":
                options.ocgoFixture = it.next().map { URL(fileURLWithPath: $0) }
            case "--debug-snapshot":
                options.debugSnapshot = it.next().map { URL(fileURLWithPath: $0) }
            case "--debug-write-test-token":
                options.debugWriteTestToken = true
            default:
                continue
            }
        }
        return options
    }
}
