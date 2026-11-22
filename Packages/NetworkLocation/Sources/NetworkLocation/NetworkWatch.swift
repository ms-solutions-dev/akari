import Foundation
import Network
import Observation

/// Observation of the network path.
///
/// **Without this there is no `NWPathMonitor` anywhere in the project:** the app does
/// not know whether it is on Wi-Fi, and the offline-store rule "Wi-Fi only" would be a
/// statement of intent. This is that line.
///
/// ``state`` counts every change. ``BandwidthMemory`` hangs off it: a measured value
/// holds for **this** path and expires as soon as anything changes, not after a time
/// of day.
@MainActor
@Observable
public final class NetworkWatch {

    public private(set) var route: NetworkPath = .none

    /// How often the path has changed. Starts at 0 and rises.
    public private(set) var state = 0

    /// Whether anyone has reported in yet.
    ///
    /// **"Not measured yet" is different from "no network", and the difference shows at
    /// launch:** ``route`` starts at `.none`, and `NWPathMonitor` only reports a moment
    /// later. Anyone who takes the default for a statement treats every launch as
    /// airplane mode. Same rule as everywhere here: `nil` means "nobody asked", not
    /// "zero".
    ///
    /// **Separate from ``state`` and not derived from it:** a report that names the same
    /// path again is still a report, but it does not count as a change, and
    /// ``BandwidthMemory`` hangs off the counter.
    public private(set) var reported = false

    /// The interfaces of the last report, for reading back in the error log: `utun3, en0`.
    ///
    /// **Because the translation carries an assumption about the tunnel** (see
    /// ``NetworkPath/init(_:)``), it should be possible to read on the device what
    /// `Network` actually reported when the bar shows up or stays away where it should
    /// not.
    public private(set) var interfaces: [String] = []

    @ObservationIgnored private var monitor: NWPathMonitor?

    public init() {}

    public func launch() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let new = NetworkPath(path)
            let names = path.availableInterfaces.map(\.name)
            Task { @MainActor in self?.adopt(new, interfaces: names) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.ms-solutions.cinelounge.netzwache"))
    }

    public func halt() {
        monitor?.cancel()
        monitor = nil
    }

    /// Looks again, **for the "Try again" button without a network.**
    ///
    /// **The way back comes by itself anyway:** `NWPathMonitor` reports as soon as
    /// something carries again, and the bar is back without anyone doing anything. The
    /// button is still right: a screen without any button feels like a dead end even
    /// when it is not, and the viewer should be able to do something instead of waiting
    /// and hoping.
    ///
    /// **Restarted instead of queried:** `Network` does not hand out a snapshot of the
    /// path; what it does is report when started. So stop and start again, which costs
    /// nothing and yields exactly one fresh report.
    public func lookUp() {
        halt()
        launch()
    }

    /// For tests and previews only.
    public func adopt(_ new: NetworkPath, interfaces: [String] = []) {
        reported = true
        self.interfaces = interfaces
        guard new != route else { return }
        route = new
        state += 1
    }
}

extension NetworkPath {
    /// Translates what `Network` reports.
    ///
    /// **A path without a radio or wired interface does not carry.** On an iPhone the
    /// offline screen did not appear in airplane mode, and `NWPathMonitor` seemed to stay
    /// silent. It was not silent, it said something wrong: WireGuard runs as a full
    /// tunnel, and in airplane mode that leaves its `utun` interface and default route
    /// standing. For `Network` there is then a path (`satisfied`, interface type
    /// `.other`), and the old translation turned that into `.other`, i.e. "carries".
    /// The tunnel leads nowhere while neither Wi-Fi nor cellular lies underneath.
    ///
    /// **So what counts now is what lies under the tunnel**, not the tunnel: Wi-Fi,
    /// cellular or wired among the available interfaces, otherwise `.none`. Same view as
    /// ``LocationDetermination/foreignInterfaces``: `utun` does not describe a network of
    /// its own.
    ///
    /// **What goes away is `.other` as a carrying path.** The case stays in the enum so
    /// tests and previews can produce it; a report from `Network` no longer yields it.
    init(_ path: NWPath) {
        self.init(
            status: path.status,
            interfaces: path.availableInterfaces.map(\.type),
            expensive: path.isExpensive, sparing: path.isConstrained)
    }

    /// The translation as a rule, **without `NWPath`, so it can be tested.** Nobody can
    /// build an `NWPath`; the list of interface types they can.
    init(
        status: NWPath.Status, interfaces: [NWInterface.InterfaceType],
        expensive: Bool = false, sparing: Bool = false
    ) {
        guard status == .satisfied else {
            self.init(kind: .none)
            return
        }
        let kind: Kind =
            if interfaces.contains(.wifi) {
                .wifi
            } else if interfaces.contains(.cellular) {
                .cellular
            } else if interfaces.contains(.wiredEthernet) {
                .wired
            } else {
                .none
            }
        guard kind != .none else {
            self.init(kind: .none)
            return
        }
        self.init(kind: kind, expensive: expensive, sparing: sparing)
    }
}
