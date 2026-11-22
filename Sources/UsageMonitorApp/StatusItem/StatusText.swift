import UsageCore

/// The menubar number for one provider: the pooled 5-hour usable share.
enum StatusText {
    static func title(for gauge: WindowGauge?) -> String {
        guard let usable = gauge?.usable else { return "--" }
        let lower = Int(usable.lower.rounded())
        let upper = Int(usable.upper.rounded())
        return lower == upper ? "\(lower)%" : "\(lower)-\(upper)%"
    }
}
