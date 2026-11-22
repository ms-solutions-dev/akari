import Network
import Testing

@testable import NetworkLocation

@Suite("NetworkPath")
struct NetworkPathTests {

    /// "Expensive" is its own attribute: a hotspot is Wi-Fi and still expensive.
    @Test("An expensive Wi-Fi is not a home network")
    func expensiveWifi() {
        let hotspot = NetworkPath(kind: .wifi, expensive: true)
        #expect(hotspot.usable)
        #expect(!hotspot.largeAmountsAcceptable)
    }

    /// Low Data Mode is an explicit request and not a guess about the line. It therefore
    /// outweighs any measurement of our own.
    @Test("Low Data Mode beats everything")
    func sparing() {
        #expect(!NetworkPath(kind: .wifi, sparing: true).largeAmountsAcceptable)
    }

    @Test("Without a network nothing works")
    func noNetwork() {
        #expect(!NetworkPath.none.usable)
        #expect(!NetworkPath.none.largeAmountsAcceptable)
    }

    @Test("An ordinary Wi-Fi carries large amounts")
    func homeNetwork() {
        #expect(NetworkPath(kind: .wifi).largeAmountsAcceptable)
    }
}

/// The translation from what `Network` reports: **the half that was only visible on a
/// device** until it took a list of interface types instead of an `NWPath`.
@Suite("NetworkPath from a report")
struct NetworkPathTranslationTests {

    /// Airplane mode, WireGuard as a full tunnel, and the offline screen did not appear.
    /// `Network` reported `satisfied` over `utun`.
    @Test("A tunnel without a radio underneath does not carry")
    func tunnelAlone() {
        let route = NetworkPath(status: .satisfied, interfaces: [.other])
        #expect(!route.usable)
    }

    @Test("A tunnel over Wi-Fi is Wi-Fi")
    func tunnelOverWifi() {
        let route = NetworkPath(status: .satisfied, interfaces: [.other, .wifi])
        #expect(route.kind == .wifi)
        #expect(route.largeAmountsAcceptable)
    }

    @Test("A tunnel over cellular is cellular, and expensive stays expensive")
    func tunnelOverCellular() {
        let route = NetworkPath(status: .satisfied, interfaces: [.other, .cellular], expensive: true)
        #expect(route.kind == .cellular)
        #expect(!route.largeAmountsAcceptable)
    }

    @Test("Without a carrying path every interface list means none")
    func unsatisfied() {
        #expect(!NetworkPath(status: .unsatisfied, interfaces: [.wifi]).usable)
        #expect(!NetworkPath(status: .requiresConnection, interfaces: [.wifi]).usable)
    }

    @Test("Loopback alone is not a network")
    func loopback() {
        #expect(!NetworkPath(status: .satisfied, interfaces: [.loopback]).usable)
    }
}
