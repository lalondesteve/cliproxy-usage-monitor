import Foundation

// Pool engine -> UI. The UI renders only these types.

/// `lower == upper` when exact.
public struct PercentRange: Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    public init(exact value: Double) {
        self.init(lower: value, upper: value)
    }

    public var isExact: Bool { lower == upper }
}

public struct GaugeBar: Equatable, Sendable {
    public let alias: String
    public let colorIndex: Int
    public let remaining: Double
    public let greyed: Bool

    public init(alias: String, colorIndex: Int, remaining: Double, greyed: Bool) {
        self.alias = alias
        self.colorIndex = colorIndex
        self.remaining = remaining
        self.greyed = greyed
    }
}

/// Hover detail for one account in one window.
public struct AccountDetail: Equatable, Sendable {
    /// The old value when the current one is unknown.
    public struct Previous: Equatable, Sendable {
        public let value: Double
        public let observedAt: Date

        public init(value: Double, observedAt: Date) {
            self.value = value
            self.observedAt = observedAt
        }
    }

    public let alias: String
    public let email: String?
    public let remaining: Double?
    public let previous: Previous?
    public let resetsAt: Date?
    public let observedAt: Date?
    public let stale: Bool
    public let usable: Bool
    public let blockedReason: String?

    public init(alias: String, email: String?, remaining: Double?, previous: Previous?,
                resetsAt: Date?, observedAt: Date?, stale: Bool, usable: Bool,
                blockedReason: String?) {
        self.alias = alias
        self.email = email
        self.remaining = remaining
        self.previous = previous
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.stale = stale
        self.usable = usable
        self.blockedReason = blockedReason
    }
}

public struct WindowGauge: Equatable, Sendable {
    public struct NextRefill: Equatable, Sendable {
        public let at: Date
        public let poolGain: Double

        public init(at: Date, poolGain: Double) {
            self.at = at
            self.poolGain = poolGain
        }
    }

    public let window: WindowKind
    public let known: Int
    public let total: Int
    /// nil when total == 0
    public let quota: PercentRange?
    /// nil when total == 0
    public let usable: PercentRange?
    /// Known accounts only, fullest first.
    public let bars: [GaugeBar]
    /// 5-hour only.
    public let nextRefill: NextRefill?
    /// At least one enabled account, and every enabled one at 100 and usable:
    /// drives "reset in 5h".
    public let allFull: Bool
    /// Weekly only, expected remaining share 0...1.
    public let pace: Double?
    public let accounts: [AccountDetail]

    public init(window: WindowKind, known: Int, total: Int, quota: PercentRange?,
                usable: PercentRange?, bars: [GaugeBar], nextRefill: NextRefill?, allFull: Bool,
                pace: Double?, accounts: [AccountDetail]) {
        self.window = window
        self.known = known
        self.total = total
        self.quota = quota
        self.usable = usable
        self.bars = bars
        self.nextRefill = nextRefill
        self.allFull = allFull
        self.pace = pace
        self.accounts = accounts
    }
}

public struct UnclassifiedDetail: Equatable, Sendable {
    public let alias: String
    public let lengthSeconds: Int?
    public let usedPercent: Double
    public let resetsAt: Date?
    public let observedAt: Date

    public init(alias: String, lengthSeconds: Int?, usedPercent: Double, resetsAt: Date?,
                observedAt: Date) {
        self.alias = alias
        self.lengthSeconds = lengthSeconds
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

public enum LockoutForecast: Equatable, Sendable {
    case safe
    case lockout(from: Date, to: Date)
    case withheld(reason: String)
    case insufficientData
}

/// One account's weekly extrapolation to its own weekly reset (plan.md "Forecast").
public struct WeeklyRunOut: Equatable, Sendable {
    public let account: AccountID
    public let alias: String
    /// nil: doesn't run out before its reset, or no burn rate.
    public let runOut: Date?
    public let resets: Date?

    public init(account: AccountID, alias: String, runOut: Date?, resets: Date?) {
        self.account = account
        self.alias = alias
        self.runOut = runOut
        self.resets = resets
    }
}

public struct ForecastSummary: Equatable, Sendable {
    public let poolBurnPerHour: Double?
    public let lockout: LockoutForecast
    /// One entry per account.
    public let weekly: [WeeklyRunOut]

    public init(poolBurnPerHour: Double?, lockout: LockoutForecast, weekly: [WeeklyRunOut]) {
        self.poolBurnPerHour = poolBurnPerHour
        self.lockout = lockout
        self.weekly = weekly
    }
}

public struct ProviderRow: Equatable, Sendable {
    public let provider: Provider
    public let fiveHour: WindowGauge?
    public let weekly: WindowGauge?
    public let monthly: WindowGauge?
    /// Hover only: alias + UnclassifiedReading fields.
    public let unclassified: [UnclassifiedDetail]
    /// nil until T11.
    public let forecast: ForecastSummary?

    public init(provider: Provider, fiveHour: WindowGauge?, weekly: WindowGauge?,
                monthly: WindowGauge?, unclassified: [UnclassifiedDetail],
                forecast: ForecastSummary?) {
        self.provider = provider
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthly = monthly
        self.unclassified = unclassified
        self.forecast = forecast
    }
}

public enum SourceStatus: Equatable, Sendable {
    case ok(at: Date)
    case authStopped(SourceError)
    case failing(SourceError, since: Date)
    case notConfigured
}

public struct DashboardModel: Equatable, Sendable {
    public let generatedAt: Date
    public let rows: [ProviderRow]
    public let sources: [SourceKind: SourceStatus]
    public let antigravity: AntigravityUsage?

    public init(generatedAt: Date, rows: [ProviderRow], sources: [SourceKind: SourceStatus],
                antigravity: AntigravityUsage? = nil) {
        self.generatedAt = generatedAt
        self.rows = rows
        self.sources = sources
        self.antigravity = antigravity
    }

    public func row(_ provider: Provider) -> ProviderRow? {
        rows.first { $0.provider == provider }
    }
}
