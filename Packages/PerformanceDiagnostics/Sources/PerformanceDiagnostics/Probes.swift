import Foundation
import Synchronization

#if canImport(QuartzCore) && os(iOS)
    import QuartzCore
#endif
#if canImport(os) && os(iOS)
    import os
#endif

/// Where the user currently is — "Start", "Comic-Leser · Sternenhof Bd. 1 · S. 37".
///
/// Readable from any thread: the hang watchdog asks while the main thread is stuck.
///
/// Plus the **spot** — the page in the reader. It appears in every hang report but opens
/// no measurement window of its own: otherwise the evaluation would split into one window per page.
final class PlaceTracker: Sendable {
    private let value = Mutex(("Start", ""))
    var current: String { value.withLock { $0.0 } }
    var spot: String { value.withLock { $0.1 } }
    /// Place and spot together, for hangs.
    var precise: String { value.withLock { $0.1.isEmpty ? $0.0 : $0.0 + " · " + $0.1 } }
    func set(_ new: String) { value.withLock { $0 = (new, "") } }
    func set(spot: String) { value.withLock { $0.1 = spot } }
}

/// **The hang watchdog**: a thread of its own posts an empty task to the main thread every
/// ``beat`` seconds. If it does not arrive within ``threshold``, the main thread hung — how
/// long is known once it finally runs.
///
/// This measures what the user feels: a tap that does not land, a swipe that stalls.
/// **Where** in the code it hung is told by the stack the watchdog takes from the main
/// thread in the middle of the hang (``StackCapture``); it is only resolved off the main thread.
///
/// **Threshold 100 ms instead of 250**: scrolling up in the webtoon felt like hanging to
/// the user while the watchdog counted zero hangs. What it missed are many single frames
/// between 100 and 250 ms — each a visible jolt on its own, none a hang by the old
/// threshold. From ``heavy`` on, a hang counts as heavy.
final class HangWatchdog: @unchecked Sendable {

    static let beat: TimeInterval = 0.05
    static let threshold: TimeInterval = 0.1
    static let heavy: TimeInterval = 0.25

    private struct Phase {
        var onTheGo: Date?
        var placeAtStart = ""
        var running = false
        var stack: [UInt]?
    }

    private let phase = Mutex(Phase())
    private let report: @Sendable (_ duration: TimeInterval, _ place: String, _ stack: [UInt]) -> Void
    private let place: PlaceTracker
    private var thread: Thread?

    init(place: PlaceTracker, report: @escaping @Sendable (TimeInterval, String, [UInt]) -> Void) {
        self.place = place
        self.report = report
    }

    func launch() {
        let alreadyOn = phase.withLock { z in
            defer { z.running = true }
            return z.running
        }
        guard !alreadyOn else { return }
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "akari" + ".diagnose.haenger"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    func stop() {
        phase.withLock { $0.running = false }
    }

    private func loop() {
        while phase.withLock({ $0.running }) {
            let now = Date()
            let pending = phase.withLock { z -> Date? in
                if z.onTheGo == nil {
                    z.onTheGo = now
                    z.placeAtStart = place.precise
                    return nil
                }
                return z.onTheGo
            }
            if pending == nil {
                DispatchQueue.main.async { [weak self] in self?.arrived() }
            } else if let start = pending, now.timeIntervalSince(start) >= Self.threshold,
                phase.withLock({ $0.stack == nil })
            {
                let stack = StackCapture.capture()
                phase.withLock { $0.stack = stack }
            }
            Thread.sleep(forTimeInterval: Self.beat)
        }
    }

    private func arrived() {
        let end = Date()
        let (start, startPlace, stack) = phase.withLock { z -> (Date?, String, [UInt]) in
            defer {
                z.onTheGo = nil
                z.stack = nil
            }
            return (z.onTheGo, z.placeAtStart, z.stack ?? [])
        }
        guard let start else { return }
        let duration = end.timeIntervalSince(start)
        if duration >= Self.threshold { report(duration, startPlace, stack) }
    }
}

/// **CPU, memory, heat of the process.**
///
/// **CPU from thread times, not from `cpu_usage`**: `thread_basic_info.cpu_usage`
/// is a moving average of the core with an unknown time constant — reports showed
/// 104 % for a two-second window in which the app barely did anything. The time consumed
/// by the process (`getrusage`) and the main thread (`thread_info`) are counters; their
/// difference over the wall-clock time is the load in the window, exactly.
enum ProcessLoad {

    /// CPU time consumed in seconds — of the whole process and of the main thread alone.
    struct Times: Sendable {
        let process: TimeInterval
        let main: TimeInterval
        let wallClock: TimeInterval
    }

    /// The counter readings now. `mainThread` is the Mach port from ``StackCapture/mainThread``;
    /// 0 leaves the main-thread share at 0.
    static func times(mainThread: thread_t) -> Times {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let process =
            TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1e6
            + TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1e6
        return Times(
            process: process, main: threadTime(mainThread),
            wallClock: ProcessInfo.processInfo.systemUptime)
    }

    /// The load between two counter readings in percent of one core — process and main thread.
    static func last(from old: Times, until new: Times) -> (process: Double, main: Double) {
        let duration = new.wallClock - old.wallClock
        guard duration > 0 else { return (0, 0) }
        return (
            max(0, (new.process - old.process) / duration * 100),
            max(0, (new.main - old.main) / duration * 100)
        )
    }

    private static func threadTime(_ thread: thread_t) -> TimeInterval {
        guard thread != 0 else { return 0 }
        var info = thread_basic_info()
        var size = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1e6
            + TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1e6
    }

    /// The memory the system charges to the app (jetsam measure), in MB.
    static func storageMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// How much the app may still allocate before jetsam kills it, in MB — only known on
    /// a device; the simulator reports 0, and 0 means "unknown" here.
    static func freeMB() -> Double? {
        #if canImport(os) && os(iOS)
            let bytes = os_proc_available_memory()
            return bytes > 0 ? Double(bytes) / 1_048_576 : nil
        #else
            return nil
        #endif
    }

    /// The thermal state as a word — "normal", "warm", "serious", "critical".
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func lowPower() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

/// **Rebuilds per view**, counted per second. A shell that is rebuilt 60 times a second
/// is a loop.
///
/// **With triggers**: 130 rebuilds per second in the comic reader, and no report said
/// which state drove them. A view can pass a snapshot of its state along with the
/// rebuild — name and number per field; the counter remembers the last one and counts
/// per field how often it changed. A rebuild in which no field changed counts as "from
/// outside": the parent rebuilt, not the view itself.
final class RebuildCounter: Sendable {

    struct Status: Equatable {
        var count = 0
        var triggers: [String: Int] = [:]
        var fromOutside = 0
        var lastSnapshot: [String: Int]?
    }

    private let counter = Mutex([String: Status]())
    private let sinceTick = Atomic<Int>(0)

    func tally(_ view: String, snapshot: [String: Int]? = nil) {
        sinceTick.wrappingAdd(1, ordering: .relaxed)
        counter.withLock { z in
            var s = z[view] ?? Status()
            s.count += 1
            if let snapshot {
                if let old = s.lastSnapshot {
                    var changed = false
                    for (field, value) in snapshot where old[field] != value {
                        s.triggers[field, default: 0] += 1
                        changed = true
                    }
                    if !changed { s.fromOutside += 1 }
                }
                s.lastSnapshot = snapshot
            }
            z[view] = s
        }
    }

    /// Returns the count since the last collection and starts over — the last snapshot
    /// stays so that the first rebuild of the next window is comparable.
    func collect() -> [String: Status] {
        counter.withLock { z in
            defer {
                for (k, s) in z { z[k] = Status(lastSnapshot: s.lastSnapshot) }
            }
            return z
        }
    }

    /// All rebuilds since the last measurement point, across all views.
    func collectTick() -> Int {
        sinceTick.exchange(0, ordering: .relaxed)
    }

    /// "126 rebuilds per second — triggers: scale ×80, page ×20, from outside ×26" (example output).
    static func text(_ state: Status, seconds: Int) -> String {
        var text = "\(state.count / max(seconds, 1)) rebuilds per second"
        let share =
            state.triggers.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) ×\($0.value)" }
            + (state.fromOutside > 0 ? ["from outside ×\(state.fromOutside)"] : [])
        if !share.isEmpty { text += " — triggers: " + share.joined(separator: ", ") }
        return text
    }
}

/// **A measurement series**: named values, summarized per window into count, mean, p95 and
/// maximum — "Page decode ms: n=42 avg 9 p95 22 max 48".
///
/// At most ``edition`` values per window are kept for the percentiles; anything beyond
/// that still counts in count, sum and maximum.
struct MeasurementSeries: Sendable {
    static let edition = 2_000

    var count = 0
    var sum = 0.0
    var maximum = 0.0
    var values: [Double] = []

    mutating func save(_ value: Double) {
        count += 1
        sum += value
        maximum = max(maximum, value)
        if values.count < Self.edition { values.append(value) }
    }

    var mean: Double { count == 0 ? 0 : sum / Double(count) }

    var p95: Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        return ordered[min(ordered.count - 1, Int((Double(ordered.count) * 0.95).rounded(.down)))]
    }

    var text: String {
        String(format: "n=%d Ø %.1f p95 %.0f max %.0f", count, mean, p95, maximum)
    }
}

/// **Summary per window**: what would be too many lines individually (CPU every 2 s, every
/// late frame) goes into the book as one line per place and window.
struct Window: Sendable {
    var cpu: [Double] = []
    var main: [Double] = []
    var storageMax = 0.0
    var freeMin: Double?
    var jankMs = 0.0
    var images = 0
    var longImages = 0
    var heavyImages = 0
    var longestImageMs = 0.0
    var series: [String: MeasurementSeries] = [:]
    var startTime = Date()

    var cpuMean: Double { cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count) }
    var mainMean: Double { main.isEmpty ? 0 : main.reduce(0, +) / Double(main.count) }
}

/// **A storm of long frames**: single late frames less than ``quiet`` apart are merged
/// into one event — otherwise scrolling for three seconds would write thirty lines. Pure
/// computation, without clock and without book, so it can be tested.
struct ImageStorm: Sendable, Equatable {
    static let quiet: TimeInterval = 1

    var startTime: Date
    var end: Date
    var count: Int
    var longestMs: Double
    var place: String

    /// Takes in a late frame; if it no longer fits this storm, the finished one is returned
    /// and a new one begins.
    mutating func save(lateMs: Double, now: Date, place: String) -> ImageStorm? {
        if now.timeIntervalSince(end) < Self.quiet {
            end = now
            count += 1
            longestMs = max(longestMs, lateMs)
            return nil
        }
        let done = self
        self = ImageStorm(startTime: now, end: now, count: 1, longestMs: lateMs, place: place)
        return done
    }

    var text: String {
        let duration = end.timeIntervalSince(startTime)
        return String(
            format: "%d frames ≥ %.0f ms in %.1f s, longest %.0f ms", count, Performance.longImageFrom,
            duration,
            longestMs)
    }
}

#if canImport(QuartzCore) && os(iOS)
    /// **The frame beat**: counts how much later a frame came than planned — Apple's
    /// "hitch time", in ms per second. Below 5 ms/s nothing is noticeable, above 10 ms/s it
    /// visibly stutters. Plus the length of the planned frame, so the delay becomes a number
    /// of missed frame changes — on ProMotion it varies between 8 and 100 ms.
    ///
    /// Runs only while recording: a frame beat keeps the screen at full frame
    /// rate and itself costs battery.
    @MainActor
    final class FrameBeat: NSObject {
        private var link: CADisplayLink?
        private var lastTarget: CFTimeInterval?
        private let report: (_ lateMs: Double, _ frameDurationMs: Double) -> Void

        init(report: @escaping (Double, Double) -> Void) {
            self.report = report
        }

        func launch() {
            guard link == nil else { return }
            let v = CADisplayLink(target: self, selector: #selector(image(_:)))
            v.add(to: .main, forMode: .common)
            link = v
        }

        func stop() {
            link?.invalidate()
            link = nil
            lastTarget = nil
        }

        @objc private func image(_ v: CADisplayLink) {
            // The previous frame was due by `lastTarget`; if this one came later, the
            // difference is the jank.
            if let target = lastTarget {
                let late = (v.timestamp - target) * 1000
                report(max(0, late), (v.targetTimestamp - v.timestamp) * 1000)
            }
            lastTarget = v.targetTimestamp
        }
    }
#endif
