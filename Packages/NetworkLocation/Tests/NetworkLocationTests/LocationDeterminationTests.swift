import Testing

@testable import NetworkLocation

/// Whether the home network is reachable directly.
///
/// **What can be tested here and what cannot.** Querying this machine's network
/// interfaces tests the machine and not the rule, and a test run whose result differs
/// from one place to the next is no test run. So what is tested is the **decision** over
/// given networks, and it carries the whole point: the question is not whether the
/// server answers, but whether it is on the device's own network.
///
/// **Verified against a real network**, with a WireGuard tunnel running: the machine was
/// on `192.0.2.33/24`, the media server on `192.0.2.184`, and `utun5` was up. The rule
/// said "at home" because of the subnet and not because the server answers.
@Suite("LocationDetermination")
struct LocationDeterminationTests {

    private let homeNetwork = LocationDetermination.NetworkInfo(
        address: 0xC000_0221, mask: 0xFFFF_FF00)  // 192.0.2.33 / 255.255.255.0

    @Test("A dotted address becomes a number")
    func parseAddress() {
        #expect(LocationDetermination.address(from: "192.0.2.184") == 0xC000_02B8)
        #expect(LocationDetermination.address(from: "0.0.0.0") == 0)
        #expect(LocationDetermination.address(from: "255.255.255.255") == 0xFFFF_FFFF)
    }

    /// **What is not an address does not become one.** `256` does not fit in a byte, `01`
    /// looks like one and is not; letting either through would end up taking a name for
    /// an address and never asking the name service.
    @Test("What is not an address yields nothing")
    func notAnAddress() {
        #expect(LocationDetermination.address(from: "jellyfin.example") == nil)
        #expect(LocationDetermination.address(from: "192.0.2") == nil)
        #expect(LocationDetermination.address(from: "192.0.2.256") == nil)
        #expect(LocationDetermination.address(from: "192.0.2.01") == nil)
        #expect(LocationDetermination.address(from: "") == nil)
    }

    @Test("In the same subnet means at home")
    func sameNetwork() {
        let server = LocationDetermination.address(from: "192.0.2.184")
        #expect(LocationDetermination.location(server: server, networks: [homeNetwork]) == .atHome)
    }

    /// **The case this is all about.** Over WireGuard the media server answers from
    /// anywhere in the world; the phone is then plugged into a different network. Anyone
    /// who defines "at home" by reachability gets "at home" on the train.
    @Test("Through the tunnel you are on the go even though the server answers")
    func onTheGoThroughTunnel() {
        // The phone is on cellular, the tunnel leads into the house, but the tunnel's
        // interface does not count as a network of its own, and the cellular network is a
        // different one.
        let cellular = LocationDetermination.NetworkInfo(address: 0x0A1E_0B0C, mask: 0xFFFF_FF00)
        let server = LocationDetermination.address(from: "192.0.2.184")

        #expect(LocationDetermination.location(server: server, networks: [cellular]) == .onTheGo)
    }

    /// **A foreign Wi-Fi is Wi-Fi too**, which is exactly the sentence in
    /// ``LocationStatement``. And if the foreign network happens to use the same numbers
    /// (here `192.0.2.x`, the default of most home routers), the rule says "at home".
    /// That is the known limit of this approach and is recorded here as a test so nobody
    /// takes it for a bug: two networks with the same address range cannot be told apart
    /// from the inside.
    @Test("A foreign network with the same numbers cannot be told apart")
    func sameNumbersForeignNetwork() {
        let foreignRouter = LocationDetermination.NetworkInfo(address: 0xC000_022A, mask: 0xFFFF_FF00)
        let server = LocationDetermination.address(from: "192.0.2.184")

        #expect(LocationDetermination.location(server: server, networks: [foreignRouter]) == .atHome)
    }

    /// **Without an answer nothing is claimed**, which is the whole purpose of
    /// ``LocationStatement/Location/unknown``.
    @Test("Without an address or a network of its own it stays unknown")
    func unknownInsteadOfGuessing() {
        #expect(LocationDetermination.location(server: nil, networks: [homeNetwork]) == .unknown)
        #expect(
            LocationDetermination.location(server: 0xC000_02B8, networks: []) == .unknown,
            "in airplane mode there is no network of its own")
        #expect(LocationDetermination.location(server: nil, networks: []) == .unknown)
    }

    /// Several interfaces at once, Wi-Fi and cellular. One match is enough.
    @Test("One matching network among several is enough")
    func severalNetworks() {
        let cellular = LocationDetermination.NetworkInfo(address: 0x0A1E_0B0C, mask: 0xFFFF_FF00)
        let server = LocationDetermination.address(from: "192.0.2.184")

        #expect(
            LocationDetermination.location(server: server, networks: [cellular, homeNetwork]) == .atHome)
    }

    /// **The tunnel is not one of the device's own networks**, otherwise the answer would
    /// be compared with the question. The list lives in the source and is pinned here so
    /// nobody shortens it while tidying up.
    @Test("Tunnel and direct-link interfaces do not count as a network of their own")
    func foreignInterfacesExcluded() {
        for name in ["utun", "awdl", "bridge", "ap", "ipsec", "ppp", "llw"] {
            #expect(LocationDetermination.foreignInterfaces.contains(name))
        }
        #expect(!LocationDetermination.foreignInterfaces.contains("en"))
        #expect(!LocationDetermination.foreignInterfaces.contains("pdp_ip"), "cellular counts")
    }

    /// Without a location there is no location line: the link between this file and what
    /// is on screen.
    @Test("With an unknown location the statement yields nothing")
    func unknownStaysSilent() {
        for place in LocationStatement.Place.allCases {
            #expect(LocationStatement.for(place, location: .unknown) == nil)
            #expect(LocationStatement.for(place, location: .atHome) != nil)
            #expect(LocationStatement.for(place, location: .onTheGo) != nil)
        }
    }
}
