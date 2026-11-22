import Foundation

/// A tolerant view over decoded JSON, for cliproxy payloads whose exact shapes aren't
/// verified yet (implementation-plan.md "Assumptions not verified", P0.2 and P0.3).
///
/// Key lookup tries each candidate name as written, then compares names with case,
/// `-`, `_` and spaces ignored, so `observedAt`, `observed_at` and `Observed-At` all
/// match. JSON `null` reads as absent.
struct CliproxyJSON {
    let raw: Any

    init(_ raw: Any) {
        self.raw = raw
    }

    static func parse(_ data: Data) throws -> CliproxyJSON {
        CliproxyJSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    static func normalize(_ key: String) -> String {
        String(key.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " })
    }

    var object: [String: Any]? { raw as? [String: Any] }

    var array: [CliproxyJSON]? { (raw as? [Any])?.map(CliproxyJSON.init) }

    /// The value of the first candidate key that is present and not null. Exact names
    /// are tried first, then normalized names, each pass in the candidates' order;
    /// keys that normalize alike are tried in sorted order, so the pick never depends
    /// on dictionary order. A blank string is a value here; fallback sites use
    /// `nonEmptyString`.
    subscript(_ keys: String...) -> CliproxyJSON? {
        guard let object else { return nil }
        for key in keys {
            if let v = object[key], !(v is NSNull) { return CliproxyJSON(v) }
        }
        let names = object.keys.sorted()
        for key in keys {
            let wanted = Self.normalize(key)
            for k in names where Self.normalize(k) == wanted {
                if let v = object[k], !(v is NSNull) { return CliproxyJSON(v) }
            }
        }
        return nil
    }

    private var isBool: Bool {
        guard let n = raw as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A string, or a number written as a string.
    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber, !isBool { return n.stringValue }
        return nil
    }

    /// A finite number, or a string holding one.
    var double: Double? {
        let value: Double?
        if let n = raw as? NSNumber, !isBool {
            value = n.doubleValue
        } else if let s = raw as? String {
            value = Double(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// A whole number that fits in `Int`, read exactly: never rounded and never through
    /// a `Double`, which loses precision above 2^53. Fractional or out-of-range values
    /// give nil (and nothing here traps on remote input).
    var int: Int? {
        if let n = raw as? NSNumber, !isBool {
            switch String(cString: n.objCType) {
            case "c", "s", "i", "l", "q": return Int(exactly: n.int64Value)
            case "C", "S", "I", "L", "Q": return Int(exactly: n.uint64Value)
            // Floating or decimal storage: its exact text, which is integer text
            // only when the value is whole ("1.5" and "1e+20" give nil).
            default: return Int(n.stringValue)
            }
        }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// `string` unless it is empty or blank (Go's zero value). For fallback chains
    /// such as `a["id"]?.nonEmptyString ?? a["name"]?.nonEmptyString`.
    var nonEmptyString: String? {
        guard let s = string, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// A JSON boolean, or the strings "true" and "false".
    var bool: Bool? {
        if isBool, let n = raw as? NSNumber { return n.boolValue }
        switch (raw as? String)?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// A Unix epoch timestamp in seconds (milliseconds when it is too large for
    /// seconds), or an RFC 3339 string. Missing, epoch 0 and Go's zero time give nil
    /// (plan.md: "unset", never "past").
    var date: Date? {
        if let seconds = double {
            let s = seconds > 100_000_000_000 ? seconds / 1000 : seconds
            let d = Date(timeIntervalSince1970: s)
            return WireDate.isUnset(d) ? nil : d
        }
        return WireDate.parse(string)
    }
}
