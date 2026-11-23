import Foundation
import UsageCore
@testable import UsageMonitorApp

/// Records every PollControl call in order.
actor T9cFakePollControl: PollControl {
    enum Call: Equatable {
        case test(SourceKind, SourceConfig)
        case configChanged(SourceKind)
        case poolSettingsChanged(PoolSettings)
    }

    private(set) var calls: [Call] = []
    private var testResult: Result<String, SourceError>

    init(testResult: Result<String, SourceError> = .success("3 credentials")) {
        self.testResult = testResult
    }

    private var observer: (@Sendable (Call) -> Void)?

    func setTestResult(_ result: Result<String, SourceError>) { testResult = result }

    /// Runs on every call as it arrives, e.g. to snapshot the saved state at that moment.
    func observe(_ observer: @escaping @Sendable (Call) -> Void) { self.observer = observer }

    private func record(_ call: Call) {
        observer?(call)
        calls.append(call)
    }

    func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError> {
        record(.test(kind, config))
        return testResult
    }

    func configChanged(_ kind: SourceKind) async { record(.configChanged(kind)) }

    func poolSettingsChanged(_ settings: PoolSettings) async {
        record(.poolSettingsChanged(settings))
    }
}

/// An in-memory SecretStore, so tests never touch the login keychain.
final class T9cFakeSecretStore: SecretStore, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var values: [Keychain.Account: String]
    private var failReads: Set<Keychain.Account> = []
    private var failWrites: Set<Keychain.Account> = []
    private var writeLog: [String] = []
    private var nextReadGate: T9cGate?

    init(_ values: [Keychain.Account: String] = [:]) {
        self.values = values
    }

    var stored: [Keychain.Account: String] { lock.withLock { values } }
    /// "write <account>" / "delete <account>", in order.
    var writes: [String] { lock.withLock { writeLog } }

    func set(_ value: String?, for account: Keychain.Account) { lock.withLock { values[account] = value } }
    /// Adds an entry to the write log, so other events can be ordered against writes.
    func note(_ entry: String) { lock.withLock { writeLog.append(entry) } }
    func failReads(_ account: Keychain.Account) { lock.withLock { _ = failReads.insert(account) } }
    func failWrites(_ accounts: Set<Keychain.Account>) { lock.withLock { failWrites = accounts } }
    func failAllWrites() { failWrites([.cliproxyKey, .ocgoToken, .debugTestToken]) }

    /// The next read blocks until the gate is released, like a pending Keychain prompt,
    /// and then reads the values current at that time.
    func holdNextRead() -> T9cGate {
        lock.withLock {
            let gate = T9cGate()
            nextReadGate = gate
            return gate
        }
    }

    func read(_ account: Keychain.Account) throws -> String? {
        let gate = lock.withLock {
            defer { nextReadGate = nil }
            return nextReadGate
        }
        gate?.block()
        return try lock.withLock {
            if failReads.contains(account) { throw Failure() }
            return values[account]
        }
    }

    func write(_ value: String, for account: Keychain.Account) throws {
        try lock.withLock {
            if failWrites.contains(account) { throw Failure() }
            values[account] = value
            writeLog.append("write \(account.rawValue)")
        }
    }

    func delete(_ account: Keychain.Account) throws {
        try lock.withLock {
            if failWrites.contains(account) { throw Failure() }
            values[account] = nil
            writeLog.append("delete \(account.rawValue)")
        }
    }
}

/// Holds one blocking call until released.
final class T9cGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var arrived = false

    var hasArrived: Bool { lock.withLock { arrived } }

    func block() {
        lock.withLock { arrived = true }
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

/// A PollControl whose `test` waits until the test finishes it, so results can land in
/// any order.
actor T9cSuspendingPollControl: PollControl {
    private(set) var tested: [SourceConfig] = []
    private var pending: [CheckedContinuation<Result<String, SourceError>, Never>?] = []

    var waiting: Int { pending.compactMap { $0 }.count }

    func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError> {
        tested.append(config)
        return await withCheckedContinuation { pending.append($0) }
    }

    /// Finishes the test call with this index (0 = first call).
    func finish(_ index: Int, with result: Result<String, SourceError>) {
        pending[index]?.resume(returning: result)
        pending[index] = nil
    }

    func configChanged(_ kind: SourceKind) async {}
    func poolSettingsChanged(_ settings: PoolSettings) async {}
}

/// Polls until `condition` holds; fails the test after 2 s.
@MainActor
func t9cWait(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw T9cTimeout(what: what)
}

struct T9cTimeout: Error { let what: String }

/// A UserDefaults suite of its own, removed when the test ends.
final class T9cDefaults {
    let name = "T9c-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }

    deinit { defaults.removePersistentDomain(forName: name) }
}
