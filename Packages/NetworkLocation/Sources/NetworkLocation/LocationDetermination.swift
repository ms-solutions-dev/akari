import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Whether the home network is reachable **directly**: determined, not asserted.
///
/// **The problem:** `location: .atHome` used to be hard-coded in three places, and
/// ``LocationStatement`` itself says why that does not work: *"Whether you are 'at home'
/// is not decided by whether Wi-Fi is present, but by whether the media server answers
/// without a tunnel; a foreign Wi-Fi is Wi-Fi too."*
///
/// **Why reachability alone is the wrong question.** Over WireGuard the media server
/// answers from anywhere in the world. Anyone who defines "at home" as "the server
/// answers" gets "at home" on the train, and that is exactly where the statements that
/// depend on it sit: whether a file is fetched at full resolution, whether the offline
/// store downloads, what the location line promises.
///
/// **The question that can be answered is a different one: is the server on *my*
/// network?** If the server's address is part of the subnet this phone itself is
/// plugged into, it is on the same network: no tunnel, no relay. If it lies outside,
/// the route leads through something, and then you are out and about. Through the
/// tunnel the phone gets an address from the WireGuard network; the server's
/// `192.0.2.184` is reachable from there, but **not** in the phone's own subnet.
///
/// **Tunnel interfaces do not count as a network of their own.** `utun` is the tunnel
/// itself; counting it would compare the answer with the question.
///
/// **What it explicitly cannot do:** IPv6. A home network that exposes the media server
/// only over IPv6 reports `unknown` here, and that is the right answer, not the
/// convenient one. Guessing a location is exactly the mistake this package removes.
public enum LocationDetermination {

    /// A network this device itself is plugged into.
    public struct NetworkInfo: Sendable, Equatable {
        public let address: UInt32
        public let mask: UInt32

        public init(address: UInt32, mask: UInt32) {
            self.address = address
            self.mask = mask
        }

        /// Is this address in this network?
        public func contains(_ target: UInt32) -> Bool {
            (target & mask) == (address & mask)
        }
    }

    /// Interfaces that do not describe a network of their own.
    ///
    /// `utun` is the tunnel, and so are `ipsec` and `ppp`; `awdl` and `llw` are Apple's
    /// direct device-to-device links, `bridge` and `ap` belong to sharing the device's
    /// own connection. None of them says anything about which house you are in.
    static let foreignInterfaces = ["utun", "awdl", "bridge", "ap", "ipsec", "ppp", "llw"]

    /// This device's networks, without tunnels.
    public static func ownNetworks() -> [NetworkInfo] {
        #if canImport(Darwin)
            var pointer: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
            defer { freeifaddrs(pointer) }

            var found: [NetworkInfo] = []
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let now = cursor {
                defer { cursor = now.pointee.ifa_next }

                let name = String(cString: now.pointee.ifa_name)
                guard !foreignInterfaces.contains(where: { name.hasPrefix($0) }) else { continue }
                guard now.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                    now.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                    let addr = now.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                    let mask = now.pointee.ifa_netmask
                else { continue }

                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                found.append(NetworkInfo(address: ip, mask: netmask))
            }
            return found
        #else
            return []
        #endif
    }

    /// A dotted address as a number, or `nil` if it is not one.
    ///
    /// **No name service.** This function resolves nothing; it reads an address that
    /// already is one. Resolving happens in ``location(for:)`` and is the part that
    /// reaches into the network, kept separate so the arithmetic stays testable.
    public static func address(from text: String) -> UInt32? {
        let share = text.split(separator: ".", omittingEmptySubsequences: false)
        guard share.count == 4 else { return nil }
        var integer: UInt32 = 0
        for part in share {
            guard let byte = UInt8(part), String(byte) == String(part) else { return nil }
            integer = (integer << 8) | UInt32(byte)
        }
        return integer
    }

    /// The decision itself, **without a network and therefore testable.**
    ///
    /// - Parameters:
    ///   - server: the media server's address as a number, or `nil` if it could not be
    ///     determined
    ///   - networks: the device's own networks from ``ownNetworks()``
    public static func location(server: UInt32?, networks: [NetworkInfo]) -> LocationStatement.Location {
        // **Without an address or without a network of its own, nothing is claimed.** Both
        // happen: a name that does not resolve right now; a device in airplane mode.
        guard let server, !networks.isEmpty else { return .unknown }
        return networks.contains { $0.contains(server) } ? .atHome : .onTheGo
    }

    /// The same for an address that may also be a name.
    ///
    /// **Name resolution runs here and not on the main thread.** `jellyfin.example` only
    /// resolves on the home network, and a resolution attempt that goes nowhere takes
    /// time.
    public static func location(for server: URL?) async -> LocationStatement.Location {
        guard let host = server?.host else { return .unknown }
        let networks = ownNetworks()
        if let immediate = address(from: host) {
            return location(server: immediate, networks: networks)
        }
        let resolved = await Task.detached(priority: .utility) { resolve(host) }.value
        return location(server: resolved, networks: networks)
    }

    /// A name to an IPv4 address.
    private static func resolve(_ host: String) -> UInt32? {
        #if canImport(Darwin)
            var hint = addrinfo(
                ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hint, &result) == 0, let first = result else {
                return nil
            }
            defer { freeaddrinfo(result) }
            guard let addr = first.pointee.ai_addr else { return nil }
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
        #else
            return nil
        #endif
    }
}
