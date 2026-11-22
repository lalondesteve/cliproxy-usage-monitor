import Foundation

/// Timestamp parsing shared by the source parsers.
enum WireDate {
    /// Parses an RFC 3339 timestamp, with any number of fractional digits (Go emits
    /// nanoseconds) and a `Z` or numeric offset. Returns nil for unset values: nil,
    /// empty, epoch 0 and Go's zero time `0001-01-01T00:00:00Z` (plan.md: "unset",
    /// never "past"), and for strings that don't parse.
    static func parse(_ string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }

        var base = s
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s[s.index(after: dot)...]
            let digits = afterDot.prefix(while: { $0.isASCII && $0.isNumber })
            fraction = Double("0." + digits) ?? 0
            base = String(s[..<dot]) + afterDot.dropFirst(digits.count)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: base) else { return nil }
        let date = whole.addingTimeInterval(fraction)
        return isUnset(date) ? nil : date
    }

    /// Epoch 0 or anything before it (covers Go's year-1 zero time).
    static func isUnset(_ date: Date) -> Bool {
        date.timeIntervalSince1970 <= 0
    }
}
