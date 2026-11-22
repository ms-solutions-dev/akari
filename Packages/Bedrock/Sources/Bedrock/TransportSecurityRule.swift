import Foundation

/// The transport security rules, as the system actually evaluates them: as
/// testable logic instead of knowledge in somebody's head.
///
/// Background: this very quirk once cost hours of searching.
/// `NSAllowsArbitraryLoads` allows unencrypted connections, **but is ignored
/// entirely** as soon as one of the more finely grained keys stands next to it.
/// The entries cancel each other out, and what remains is the narrow rule, which
/// does not know self-assigned suffixes such as `.home`. The failure appears as
/// `-1022` before any connection is made at all, which is easily mistaken for a
/// network problem.
public enum TransportSecurityRule {

    /// The keys whose presence overrides `NSAllowsArbitraryLoads`.
    public static let overridingKeys = [
        "NSAllowsLocalNetworking",
        "NSAllowsArbitraryLoadsInWebContent",
        "NSAllowsArbitraryLoadsForMedia",
    ]

    public enum Verdict: Equatable {
        /// Unencrypted connections to any address are allowed.
        case allowsAnyPlainHTTP
        /// Only to addresses on the local network, without a dot or ending in `.local`.
        /// Self-assigned suffixes such as `.home` are **not** covered.
        case allowsLocalOnly(ineffectiveArbitraryLoads: Bool)
        /// Encrypted connections only.
        case requiresHTTPS

        /// Whether an address such as `jellyfin.example` would be reachable with it.
        public var permitsCustomDomainNames: Bool {
            self == .allowsAnyPlainHTTP
        }
    }

    /// Evaluates a configuration the way the system does.
    public static func evaluate(_ settings: [String: Bool]) -> Verdict {
        let arbitrary = settings["NSAllowsArbitraryLoads"] ?? false
        let overriding = overridingKeys.contains { settings[$0] == true }

        if arbitrary && !overriding {
            return .allowsAnyPlainHTTP
        }
        if settings["NSAllowsLocalNetworking"] == true {
            // The decisive case: the broad permission is present but does not take effect,
            // and that is exactly what is overlooked when reading.
            return .allowsLocalOnly(ineffectiveArbitraryLoads: arbitrary)
        }
        return .requiresHTTPS
    }
}
