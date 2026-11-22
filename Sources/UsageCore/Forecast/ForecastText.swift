import Foundation

/// Text for the weekly run-out (plan.md "Forecast" outputs: "weekly runs out Wed 18:00,
/// resets Thu 09:00"). The rest of the dropdown text is T11d.
public enum ForecastText {
    /// "runs out Fri 12:00, resets Sat 12:00"; without a known reset, "runs out Fri
    /// 12:00". nil when the account doesn't run out before its reset.
    public static func weekly(_ r: WeeklyRunOut, timeZone: TimeZone = .current) -> String? {
        guard let runOut = r.runOut else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE HH:mm"
        var text = "runs out \(f.string(from: runOut))"
        if let resets = r.resets { text += ", resets \(f.string(from: resets))" }
        return text
    }
}
