import Foundation

/// Command-line options, for development only. Unknown arguments (such as the ones
/// macOS adds when it launches an app) are ignored.
struct LaunchOptions: Equatable {
    /// A capture folder (the layout of `Tests/UsageCoreTests/Fixtures/live/`) that both
    /// sources read instead of the network. Settings, secrets and history then stay
    /// out of UserDefaults.standard, the Keychain and Application Support.
    var fixtures: URL?
    /// Pins the clock (RFC 3339), e.g. to a capture's time. Used with `--fixtures`.
    var now: Date?
    /// Writes a PNG of the status item button here after each published model.
    var debugSnapshot: URL?
    /// Options given without a usable value. The app refuses to start with any, so a
    /// mistyped `--fixtures` never falls through to the live pipeline.
    var problems: [String] = []

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--fixtures":
                if let path = value(&it) {
                    options.fixtures = URL(fileURLWithPath: path, isDirectory: true)
                } else {
                    options.problems.append("--fixtures needs a capture folder")
                }
            case "--now":
                if let date = value(&it).flatMap(Self.date) {
                    options.now = date
                } else {
                    options.problems.append("--now needs an RFC 3339 time, e.g. 2026-11-22T12:00:00Z")
                }
            case "--debug-snapshot":
                if let path = value(&it) {
                    options.debugSnapshot = URL(fileURLWithPath: path)
                } else {
                    options.problems.append("--debug-snapshot needs a file path")
                }
            default:
                continue
            }
        }
        return options
    }

    /// The next argument, unless it's missing, empty or another option.
    private static func value(_ it: inout IndexingIterator<ArraySlice<String>>) -> String? {
        guard let next = it.next(), !next.isEmpty, !next.hasPrefix("--") else { return nil }
        return next
    }

    private static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
