import Foundation

/// A database path in a fresh temporary directory, deleted with the value.
final class T5TempDatabase: Sendable {
    let directory: URL
    let path: String

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("history.sqlite").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
