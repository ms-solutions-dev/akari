import Foundation
import Synchronization

#if canImport(MetricKit) && os(iOS)
    import MetricKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

/// **The performance diagnostics of Akari.**
///
/// Three sources that complement each other:
///
/// * **The probes** — hang watchdog, frame beat, CPU and memory, rebuilds — say
///   **when and where** it stutters. They run only while ``record(_:)`` is on: a watchdog that
///   nudges the main thread twenty times a second, and a frame beat, cost battery themselves —
///   exactly what is being looked for.
/// * **The time series** (``TimeSeries``) writes a measurement point every 250 ms — CPU, frames,
///   memory, heat, place, scroll phase, levels of the areas, network. It shows what was
///   *before* an event and goes into the report as CSV.
/// * **MetricKit** says **where in the code**: for TestFlight builds the system delivers hangs
///   and CPU outliers with a call stack from the real device the next day. Always on; it costs nothing.
///
/// Areas report their place with ``place(_:)``, special moments with ``remark(_:)``,
/// rebuilds with ``build(_:)``, measurements with ``measure(_:_:)``, levels with ``level(_:_:)``,
/// scroll phases with ``scroll(_:_:)`` and network requests with ``network(_:)`` — all cheap enough for
/// the body of a view. Nothing leaves by itself: ``report(edition:)`` writes
/// files that the user shares.
///
/// **Second stage**: hangs from 100 ms with stack, single long frames as a storm,
/// rebuilds with trigger, CPU from thread times instead of `cpu_usage`, main-thread share,
/// measurement series for the page loader, heat and low-power mode, network per request and
/// network path, the time series — and in the report
/// the timeline around each heavy event.
public enum Performance {

    /// The switch in the settings.
    /// Storage key (UserDefaults): stays `diagnose.aufzeichnen`, although a catalog key of that text exists.
    public static let recordKey = "diagnose.aufzeichnen"

    static let book = DiagnosticsLog(file: DiagnosticsFiles.folder?.appending(path: "ereignisse" + ".jsonl"))
    static let bookSeries = TimeSeries(file: DiagnosticsFiles.folder?.appending(path: "zeitreihe" + ".csv"))
    static let placeTracker = PlaceTracker()
    static let builds = RebuildCounter()
    private static let window = Mutex([String: Window]())
    private static let active = Atomic<Bool>(false)
    private static let lastTimes = Mutex<ProcessLoad.Times?>(nil)
    private static let storm = Mutex<ImageStorm?>(nil)
    private static let beat = Mutex(BeatCounter())
    private static let levels = Mutex([String: Int]())
    private static let scrollPhase = Mutex("")
    private static let networkRunning = Mutex(0)
    private static let networkLoad = Mutex(NetworkLoad())
    private static let requests = Mutex<[NetworkRequest]>([])
    private static let tickCounter = Atomic<Int>(0)
    /// This many requests are kept in memory for the CSV attachment.
    static let requestsEdition = 2_000

    nonisolated(unsafe) private static var watchdog: HangWatchdog?
    nonisolated(unsafe) private static var clock: DispatchSourceTimer?
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private static var networkPath: NetworkPathWatch?
    #if canImport(QuartzCore) && os(iOS)
        @MainActor private static var frameBeat: FrameBeat?
    #endif

    /// Whether the probes are running.
    public static var records: Bool { active.load(ordering: .relaxed) }

    // MARK: - Start

    /// At program start: register MetricKit and, if enabled, start the probes.
    @MainActor
    public static func launch(settings: UserDefaults = .standard) {
        StackCapture.rememberMainThread()
        #if canImport(MetricKit) && os(iOS)
            MetricReceiver.signIn()
        #endif
        if settings.bool(forKey: recordKey) { record(true) }
    }

    /// Switches the probes on or off.
    @MainActor
    public static func record(_ to: Bool) {
        guard to != records else { return }
        active.store(to, ordering: .relaxed)
        if to {
            lastTimes.withLock { $0 = ProcessLoad.times(mainThread: StackCapture.mainThread) }
            let w = HangWatchdog(place: placeTracker, report: reportHang)
            w.launch()
            watchdog = w
            clock = Self.makeClock()
            observers = Self.makeObservers()
            let n = NetworkPathWatch { route in
                book.write(Event(kind: .phase, place: placeTracker.current, text: "Network \(route)"))
            }
            n.launch()
            networkPath = n
            #if canImport(QuartzCore) && os(iOS)
                let b = FrameBeat { late, frameDuration in recordImage(late, frameDuration) }
                b.launch()
                frameBeat = b
            #endif
            remark(
                "Recording on — thermal \(ProcessLoad.thermal())"
                    + (ProcessLoad.lowPower() ? ", low-power mode on" : ""))
        } else {
            remark("Recording off")
            watchdog?.stop()
            watchdog = nil
            clock?.cancel()
            clock = nil
            for b in observers { NotificationCenter.default.removeObserver(b) }
            observers = []
            networkPath?.stop()
            networkPath = nil
            #if canImport(QuartzCore) && os(iOS)
                frameBeat?.stop()
                frameBeat = nil
            #endif
            closeStorm()
            closeWindow()
        }
    }

    /// **Created outside any main-actor binding**: a closure that originates in the
    /// `@MainActor` function ``record(_:)`` inherits its isolation, and Swift 6
    /// aborts hard (`dispatch_assert_queue_fail`) when it runs in the background — as
    /// happened on the first trial run, three times in a row.
    ///
    /// Every 250 ms a measurement point; every eighth beat triggers the two-second work
    /// (rebuild storms, window maturity).
    nonisolated private static func makeClock() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + TimeSeries.beat, repeating: TimeSeries.beat, leeway: .milliseconds(20))
        t.setEventHandler { tick() }
        t.resume()
        return t
    }

    /// Heat and low-power mode report themselves — a device that gets warm while scrolling and
    /// throttles hangs differently from one that stays cool.
    nonisolated private static func makeObservers() -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        return [
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: queue
            ) { _ in
                book.write(
                    Event(kind: .phase, place: placeTracker.current, text: "Thermal \(ProcessLoad.thermal())")
                )
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: queue) {
                _ in
                book.write(
                    Event(
                        kind: .phase, place: placeTracker.current,
                        text: "Low-power mode " + (ProcessLoad.lowPower() ? "on" : "off")))
            },
        ]
    }

    /// Resolve the stack off the main thread: 48 `dladdr` calls including demangling cost
    /// milliseconds, and the main thread has only just got some air again.
    nonisolated private static func reportHang(_ duration: TimeInterval, _ place: String, _ stack: [UInt]) {
        let time = Date()
        DispatchQueue.global(qos: .utility).async {
            let lines = StackCapture.resolve(stack)
            let text =
                "Main thread blocked \(Int(duration * 1000)) ms"
                + (duration >= HangWatchdog.heavy ? " (heavy)" : "")
            book.write(
                Event(
                    time: time, kind: .hang, place: place,
                    text: lines.isEmpty ? text : text + "\n      " + lines.joined(separator: "\n      ")))
        }
    }

    // MARK: - Reports from the areas

    /// The place where the user is now. A change closes the measurement window of the old one.
    public static func place(_ new: String) {
        let old = placeTracker.current
        guard new != old else { return }
        placeTracker.set(new)
        scrollPhase.withLock { $0 = "" }
        guard records else { return }
        closeStorm()
        closeWindow(only: old)
        book.write(Event(kind: .place, place: new, text: "from \(old)"))
    }

    /// The spot within the place — "S. 37". Goes into hang reports, without an event.
    public static func spot(_ text: String) {
        placeTracker.set(spot: text)
    }

    /// A moment that should appear in the report — "Page 37 in 1840 ms".
    public static func remark(_ text: String) {
        guard records else { return }
        book.write(Event(kind: .remark, place: placeTracker.precise, text: text))
    }

    /// Counts a rebuild — in the body of a view: `let _ = Performance.build("Shell")`.
    public static func build(_ view: String) {
        guard records else { return }
        builds.tally(view)
    }

    /// Counts a rebuild **with a state snapshot**: name and number per field that the
    /// view can rebuild. The report then says which field drove the storm — or that
    /// none did and the parent rebuilt. The snapshot is only computed while
    /// recording.
    public static func build(_ view: String, snapshot: () -> [String: Int]) {
        guard records else { return }
        builds.tally(view, snapshot: snapshot())
    }

    /// A value in a named series — "Page decode ms", 9.4. Per window and place
    /// this becomes one line with count, mean, p95 and maximum.
    public static func measure(_ bookSeries: String, _ value: Double) {
        guard records else { return }
        let place = placeTracker.current
        window.withLock { f in
            f[place, default: Window()].series[bookSeries, default: MeasurementSeries()].save(value)
        }
    }

    /// A level — a value that *stands*, not happens: "Loader queue", 12. Every
    /// measurement point of the time series carries the last state of all levels.
    public static func level(_ name: String, _ value: Int) {
        guard records else { return }
        levels.withLock { $0[name] = value }
    }

    /// The scroll phase of the place — "Finger", "gleitet", "ruht" — for the time series; the
    /// change goes into the log as a remark.
    /// An evaluated drag (``Event/Kind/breadcrumb``) — the reader computes, the diagnostics record.
    public static func breadcrumb(_ text: String) {
        guard records else { return }
        book.write(Event(kind: .breadcrumb, place: placeTracker.precise, text: text))
    }

    public static func scroll(_ phase: String, _ extra: String = "") {
        guard records else { return }
        scrollPhase.withLock { $0 = phase }
        remark("Scrolling: \(phase)" + (extra.isEmpty ? "" : " — \(extra)"))
    }

    /// A network request has begun — for the number of running ones in the measurement point.
    public static func networkStarted() {
        guard records else { return }
        networkRunning.withLock { $0 += 1 }
    }

    /// A network request has ended. Slow ones (from ``networkSlowFrom``) and failed ones go into the log
    /// as an event, all of them into series, time series and the CSV attachment.
    public static func network(_ a: NetworkRequest) {
        guard records else { return }
        networkRunning.withLock { $0 = max(0, $0 - 1) }
        networkLoad.withLock { $0.save(a) }
        requests.withLock { list in
            list.append(a)
            if list.count > requestsEdition { list.removeFirst(list.count - requestsEdition) }
        }
        if !a.cancelled, a.failure == nil {
            measure("Network \(a.kind) 1st byte ms", a.firstByteMs)
            measure("Network \(a.kind) wait ms", a.waitMs)
            measure("Network \(a.kind) total ms", a.totalMs)
        }
        if a.totalMs >= networkSlowFrom || (a.failure != nil && !a.cancelled) {
            book.write(Event(time: a.time, kind: .network, place: placeTracker.precise, text: a.text))
        }
    }

    /// A finished task of the session, with metrics and error — the form a
    /// `URLSessionTaskDelegate` delivers.
    public static func network(task: URLSessionTask, metrics: URLSessionTaskMetrics?, failure: Error?) {
        guard records else { return }
        network(NetworkRequest(task: task, metrics: metrics, failure: failure))
    }

    // MARK: - Windows and beat

    /// From this much CPU on average of a window it counts as sustained load.
    static let sustainedLoadFrom = 40.0
    /// From this many rebuilds per second it is reported.
    static let rebuildFrom = 20
    /// From this much jank (ms per second) it is reported.
    static let jankFrom = 5.0
    /// From this much delay a single frame counts as long — a 120 Hz frame is 8 ms,
    /// 50 ms of delay are six dropped frames, visible as a jolt.
    public static let longImageFrom = 50.0
    /// From this much delay a frame counts as heavy — the finger visibly stalls.
    static let heavyImageFrom = 100.0
    /// From this total duration a network request is logged individually.
    static let networkSlowFrom = 1_000.0
    /// This long a window collects before it goes into the book.
    static let windowDuration: TimeInterval = 30

    /// What the frame beat counts between two measurement points.
    struct BeatCounter: Sendable {
        var images = 0
        var missed = 0
        var longestMs = 0.0
        var jankMs = 0.0
    }

    /// One beat of the clock: the measurement point, and every eighth the two-second work.
    private static func tick() {
        let startTime = ContinuousClock.now
        let now = ProcessLoad.times(mainThread: StackCapture.mainThread)
        let old = lastTimes.withLock { z -> ProcessLoad.Times? in
            defer { z = now }
            return z
        }
        let last = old.map { ProcessLoad.last(from: $0, until: now) } ?? (process: 0, main: 0)
        let storage = ProcessLoad.storageMB()
        let freeMemory = ProcessLoad.freeMB()
        let thermal = ProcessLoad.thermal()
        let place = placeTracker.current
        let images = beat.withLock { t -> BeatCounter in
            defer { t = BeatCounter() }
            return t
        }
        let network = networkLoad.withLock { n -> NetworkLoad in
            defer { n = NetworkLoad() }
            return n
        }
        let build = builds.collectTick()
        window.withLock { f in
            var w = f[place] ?? Window()
            w.cpu.append(last.process)
            w.main.append(last.main)
            w.storageMax = max(w.storageMax, storage)
            if let freeMemory { w.freeMin = min(w.freeMin ?? freeMemory, freeMemory) }
            f[place] = w
        }
        let ownCost = Int((ContinuousClock.now - startTime) / .microseconds(1))
        bookSeries.save(
            Sample(
                time: Date(), cpu: last.process, main: last.main, images: images.images,
                missed: images.missed, longestMs: images.longestMs, jankMs: images.jankMs,
                storageMB: storage, freeMB: freeMemory, thermal: thermal, place: place,
                spot: placeTracker.spot,
                scroll: scrollPhase.withLock { $0 }, builds: build, level: levels.withLock { $0 },
                networkRunning: networkRunning.withLock { $0 }, networkDone: network.done,
                networkBytes: network.bytes, networkFirstByteMs: network.firstByteMedian,
                networkFirstByteMaxMs: network.firstByteMax, networkAborts: network.aborts,
                networkError: network.failure,
                networkPath: networkPath?.current ?? "", tickMicros: ownCost))
        measure("Diagnostics own cost µs", Double(ownCost))
        let beatNumber = tickCounter.wrappingAdd(1, ordering: .relaxed).oldValue + 1
        if beatNumber % 8 == 0 { measureLoad(place) }
    }

    /// The two-second work: report rebuild storms, close mature windows.
    private static func measureLoad(_ place: String) {
        let mature = window.withLock { f in
            f[place].map { Date().timeIntervalSince($0.startTime) >= windowDuration } ?? false
        }
        for (view, state) in builds.collect() where state.count / 2 >= rebuildFrom {
            book.write(
                Event(
                    kind: .rebuilt, place: place,
                    text: "\(view): " + RebuildCounter.text(state, seconds: 2)))
        }
        if mature { closeWindow(only: place) }
    }

    /// Every frame from the frame beat: the sum for the window, the beat counter and, from
    /// ``longImageFrom``, the storm.
    private static func recordImage(_ lateMs: Double, _ frameDurationMs: Double) {
        let place = placeTracker.current
        beat.withLock { t in
            t.images += 1
            if lateMs > 1 {
                t.jankMs += lateMs
                t.missed += Int((lateMs / max(frameDurationMs, 1)).rounded())
            }
            t.longestMs = max(t.longestMs, lateMs)
        }
        window.withLock { f in
            var w = f[place, default: Window()]
            w.images += 1
            if lateMs > 1 { w.jankMs += lateMs }
            if lateMs >= longImageFrom {
                w.longImages += 1
                w.longestImageMs = max(w.longestImageMs, lateMs)
            }
            if lateMs >= heavyImageFrom { w.heavyImages += 1 }
            f[place] = w
        }
        guard lateMs >= longImageFrom else { return }
        let now = Date()
        let precise = placeTracker.precise
        let done = storm.withLock { s -> ImageStorm? in
            guard s != nil else {
                s = ImageStorm(startTime: now, end: now, count: 1, longestMs: lateMs, place: precise)
                return nil
            }
            return s?.save(lateMs: lateMs, now: now, place: precise)
        }
        if let done { write(done) }
    }

    /// Close the running storm — on place change, on report, on switching off.
    private static func closeStorm() {
        let done = storm.withLock { s -> ImageStorm? in
            defer { s = nil }
            return s
        }
        if let done { write(done) }
    }

    private static func write(_ s: ImageStorm) {
        book.write(Event(time: s.startTime, kind: .longImages, place: s.place, text: s.text))
    }

    /// Writes the summary of a window (or all) into the book and starts over.
    static func closeWindow(only place: String? = nil) {
        let done = window.withLock { f -> [(String, Window)] in
            let selection = f.filter { place == nil || $0.key == place }
            for k in selection.keys { f[k] = nil }
            return Array(selection)
        }
        for (place, w) in done {
            let seconds = max(Date().timeIntervalSince(w.startTime), 1)
            let jank = w.jankMs / seconds
            let cpu = w.cpuMean
            var text = String(
                format:
                    "CPU avg %.0f %% (max %.0f %%), main thread avg %.0f %% (max %.0f %%), memory max %.0f MB",
                cpu, w.cpu.max() ?? 0, w.mainMean, w.main.max() ?? 0, w.storageMax)
            if let freeMemory = w.freeMin { text += String(format: " (free %.0f MB)", freeMemory) }
            text += String(format: ", jank %.1f ms/s", jank)
            if w.longImages > 0 {
                text += String(
                    format: ", long frames %d (of which ≥ %.0f ms: %d, longest %.0f ms)", w.longImages,
                    heavyImageFrom, w.heavyImages, w.longestImageMs)
            }
            text += ", thermal \(ProcessLoad.thermal()), \(Int(seconds)) s"
            book.write(Event(kind: .last, place: place, text: text))
            if cpu >= sustainedLoadFrom {
                book.write(
                    Event(kind: .sustainedLoad, place: place, text: String(format: "CPU Ø %.0f %%", cpu)))
            }
            if jank >= jankFrom {
                book.write(Event(kind: .jank, place: place, text: String(format: "%.1f ms/s", jank)))
            }
            for (name, bookSeries) in w.series.sorted(by: { $0.key < $1.key }) {
                book.write(Event(kind: .metering, place: place, text: "\(name): \(bookSeries.text)"))
            }
        }
    }

    // MARK: - Report

    /// What ``report(edition:)`` writes: the readable report and the raw data next to it.
    public struct ReportFiles: Sendable {
        public let report: URL
        public let timeSeries: URL?
        public let requests: URL?

        /// All files for sharing — the report first.
        public var all: [URL] { [report] + [timeSeries, requests].compactMap { $0 } }
    }

    /// Writes the report with time series and requests as files — for sharing.
    public static func report(edition: String) -> ReportFiles {
        closeStorm()
        closeWindow()
        let points = bookSeries.all
        let list = requests.withLock { $0 }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let folder = FileManager.default.temporaryDirectory
        let text = ReportText.build(
            edition: edition, device: device(), recording: records, events: book.all,
            metrics: DiagnosticsFiles.metrics(), points: points, requests: list.count)
        let target = folder.appending(path: "Akari-Diagnose-\(stamp).txt")
        try? text.write(to: target, atomically: true, encoding: .utf8)
        var timeSeries: URL?
        if !points.isEmpty {
            let z = folder.appending(path: "Akari-TimeSeries-\(stamp).csv")
            if (try? TimeSeries.csv(points).write(to: z, atomically: true, encoding: .utf8)) != nil {
                timeSeries = z
            }
        }
        var requestsFile: URL?
        if !list.isEmpty {
            let a = folder.appending(path: "Akari-Requests-\(stamp).csv")
            if (try? NetworkRequest.csv(list).write(to: a, atomically: true, encoding: .utf8)) != nil {
                requestsFile = a
            }
        }
        return ReportFiles(report: target, timeSeries: timeSeries, requests: requestsFile)
    }

    /// Deletes book, time series, requests and MetricKit reports.
    public static func clearOut() {
        book.clearOut()
        bookSeries.clearOut()
        requests.withLock { $0.removeAll() }
        DiagnosticsFiles.clearMetrics()
    }

    private static func device() -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(model), \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// Where the diagnostics keep their files — in the cache, since everything in it is replaceable.
enum DiagnosticsFiles {

    static let folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "diagnose")

    static var metricsFolder: URL? { folder?.appending(path: "metrickit") }

    static func secure(metric data: Data, name: String) {
        guard let folder = metricsFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appending(path: name), options: .atomic)
    }

    /// The saved MetricKit reports, the newest last.
    static func metrics() -> [(name: String, text: String)] {
        guard let folder = metricsFolder,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        return names.sorted().compactMap { name in
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else {
                return nil
            }
            return (name, text)
        }
    }

    static func clearMetrics() {
        if let folder = metricsFolder { try? FileManager.default.removeItem(at: folder) }
    }
}

#if canImport(MetricKit) && os(iOS)
    /// The receiver for MetricKit: stores every delivery as JSON.
    ///
    /// **Diagnostics** (hangs with stack, CPU and memory outliers, crashes) arrive for
    /// TestFlight builds at the latest the next day; **metrics** (CPU time, hang rate, energy)
    /// once a day. Both go unchanged into the report — the stacks are resolved on a
    /// workstation with the build's dSYM.
    final class MetricReceiver: NSObject, MXMetricManagerSubscriber {

        @MainActor static let shared = MetricReceiver()

        @MainActor static func signIn() {
            MXMetricManager.shared.add(shared)
            // What was delivered before launch and not yet collected.
            shared.didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        }

        nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
            for (i, p) in payloads.enumerated() {
                DiagnosticsFiles.secure(
                    metric: p.jsonRepresentation(), name: Self.name("metrik", p.timeStampEnd, i))
            }
            if !payloads.isEmpty {
                Performance.book.write(
                    Event(kind: .metrickit, place: "-", text: "\(payloads.count) daily metrics received"))
            }
        }

        nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for (i, p) in payloads.enumerated() {
                DiagnosticsFiles.secure(
                    metric: p.jsonRepresentation(), name: Self.name("diagnose", p.timeStampEnd, i))
            }
            if !payloads.isEmpty {
                let hang = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
                Performance.book.write(
                    Event(
                        kind: .metrickit, place: "-",
                        text: "\(payloads.count) diagnostics received, \(hang) hangs with stack"))
            }
        }

        private static func name(_ kind: String, _ time: Date, _ i: Int) -> String {
            "\(kind)-\(Int(time.timeIntervalSince1970))-\(i).json"
        }
    }
#endif
