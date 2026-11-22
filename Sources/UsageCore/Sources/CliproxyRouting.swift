import Foundation

/// plan.md "Routing": the strategy comes from `GET /v0/management/routing/strategy`
/// (which answers the default when the config omits it), session affinity from the
/// `routing` object of `GET /v0/management/config`. Shapes aren't verified (P0.2).
enum CliproxyRoutingParser {
    /// `{"strategy": "..."}`, a few alternative wrappings, or a bare JSON string.
    static func strategy(_ data: Data) -> RoutingConfig.Strategy? {
        guard let root = try? CliproxyJSON.parse(data) else { return nil }
        let value = root.string
            ?? root["strategy", "routing-strategy", "value"]?.string
            ?? root["routing"]?["strategy"]?.string
        return value.flatMap(strategy(named:))
    }

    /// cliproxy's names, plus the short forms its config accepts.
    static func strategy(named name: String) -> RoutingConfig.Strategy? {
        switch CliproxyJSON.normalize(name) {
        case "roundrobin", "rr": .roundRobin
        case "weightedroundrobin", "wrr", "weighted": .weightedRoundRobin
        case "fillfirst", "ff": .fillFirst
        default: nil
        }
    }

    /// Reads the `routing` object of a config body (the full config, or the
    /// `{"routing": ...}` extract that capture-fixtures.sh saves). Session affinity
    /// may be a boolean or an object with `enabled`; absent means off. nil when the
    /// body isn't a JSON object.
    static func sessionAffinity(_ data: Data) -> Bool? {
        guard let root = try? CliproxyJSON.parse(data), root.object != nil else { return nil }
        guard let affinity = root["routing"]?["session-affinity"] else { return false }
        return affinity.bool ?? affinity["enabled"]?.bool ?? false
    }
}
