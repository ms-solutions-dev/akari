import Foundation
import Network
import Synchronization
import Testing

@testable import PerformanceDiagnostics

@Suite("Diagnostics")
struct DiagnosticsTests {

    @Test("The hang watchdog reports a blocked main thread with duration, place and stack")
    @MainActor
    func hang() async throws {
        let reported = Mutex<[(Double, String)]>([])
        let place = PlaceTracker()
        place.set("Comic reader · S. 37")
        StackCapture.rememberMainThread()
        let stack = Mutex<[UInt]>([])
        let w = HangWatchdog(place: place) { duration, o, s in
            reported.withLock { $0.append((duration, o)) }
            stack.withLock { $0 = s }
        }
        w.launch()
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(200))
        // Control check: nothing without a blockage.
        #expect(reported.withLock { $0.isEmpty })
        // Block the main thread for 600 ms.
        usleep(600_000)
        try await Task.sleep(for: .milliseconds(200))
        let list = reported.withLock { $0 }
        #expect(list.count == 1)
        // Above the reporting threshold, not "at least 0.5 s": the watchdog measures from its last
        // ping, and under the load of the full test run its own thread is scheduled later too
        // (once red with count 1 but a shorter duration).
        #expect((list.first?.0 ?? 0) >= HangWatchdog.threshold)
        #expect(list.first?.1 == "Comic reader · S. 37")
        // The stack shows where the main thread stood — here in this test's sleep.
        let resolved = StackCapture.resolve(stack.withLock { $0 })
        #expect(resolved.contains { $0.contains("usleep") || $0.contains("nanosleep") })
    }

    @Test("The book keeps the newest events, oldest first")
    func ringBuffer() {
        let book = DiagnosticsLog(file: nil)
        for i in 0..<(DiagnosticsLog.edition + 5) {
            book.write(Event(kind: .remark, place: "x", text: "\(i)"))
        }
        let all = book.all
        #expect(all.count == DiagnosticsLog.edition)
        #expect(all.first?.text == "5")
        #expect(all.last?.text == "\(DiagnosticsLog.edition + 4)")
    }

    @Test("Process load is computed from thread times: computing costs CPU, sleeping does not")
    func last() {
        // The own thread, not `StackCapture.mainThread`: the hang watchdog test sets that
        // to its own thread in parallel.
        let thread = mach_thread_self()
        let quiet = ProcessLoad.times(mainThread: thread)
        usleep(100_000)
        let afterQuiet = ProcessLoad.times(mainThread: thread)
        var sum = 0.0
        let startTime = ContinuousClock.now
        while ContinuousClock.now - startTime < .milliseconds(120) { sum += sin(sum + 1) }
        let afterWork = ProcessLoad.times(mainThread: thread)
        let calm = ProcessLoad.last(from: quiet, until: afterQuiet)
        let busy = ProcessLoad.last(from: afterQuiet, until: afterWork)
        #expect(sum != 0)
        #expect(calm.main < 30)
        #expect(busy.main > 50)
        #expect(busy.process >= busy.main - 1)
        #expect(ProcessLoad.storageMB() > 1)
        #expect(["normal", "warm", "serious", "critical", "unknown"].contains(ProcessLoad.thermal()))
    }

    @Test("The rebuild counter names which field drove the rebuild — and if none, the parent")
    func triggers() {
        let z = RebuildCounter()
        z.tally("Leser", snapshot: ["seite": 1, "hud": 0])
        z.tally("Leser", snapshot: ["seite": 2, "hud": 0])
        z.tally("Leser", snapshot: ["seite": 3, "hud": 0])
        z.tally("Leser", snapshot: ["seite": 3, "hud": 1])
        z.tally("Leser", snapshot: ["seite": 3, "hud": 1])
        let state = try! #require(z.collect()["Leser"])
        #expect(state.count == 5)
        #expect(state.triggers["seite"] == 2)
        #expect(state.triggers["hud"] == 1)
        #expect(state.fromOutside == 1)
        #expect(z.collectTick() == 5)
        #expect(z.collectTick() == 0)
        let text = RebuildCounter.text(state, seconds: 1)
        #expect(text.contains("seite ×2"))
        #expect(text.contains("from outside ×1"))
        // After collecting, the snapshot stays: the next rebuild with the same state is "from outside".
        z.tally("Leser", snapshot: ["seite": 3, "hud": 1])
        #expect(z.collect()["Leser"]?.fromOutside == 1)
    }

    @Test("A measurement series summarizes into count, mean, p95 and maximum")
    func measurementSeries() {
        var r = MeasurementSeries()
        for i in 1...100 { r.save(Double(i)) }
        #expect(r.count == 100)
        #expect(r.mean == 50.5)
        #expect(r.p95 == 96)
        #expect(r.maximum == 100)
        #expect(r.text == "n=100 Ø 50.5 p95 96 max 100")
    }

    @Test("An image storm merges late frames until there was one second of quiet")
    func imageStorm() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var s = ImageStorm(startTime: t0, end: t0, count: 1, longestMs: 60, place: "Reader")
        #expect(s.save(lateMs: 140, now: t0.addingTimeInterval(0.3), place: "Reader") == nil)
        #expect(s.save(lateMs: 70, now: t0.addingTimeInterval(0.9), place: "Reader") == nil)
        let done = s.save(lateMs: 55, now: t0.addingTimeInterval(2.5), place: "Start")
        #expect(done?.count == 3)
        #expect(done?.longestMs == 140)
        #expect(done?.text == "3 frames ≥ 50 ms in 0.9 s, longest 140 ms")
        #expect(s.count == 1)
        #expect(s.place == "Start")
    }

    @Test("The time series keeps the last points, condenses per second and writes CSV")
    func timeSeries() {
        let bookSeries = TimeSeries(file: nil)
        let t0 = Date(timeIntervalSince1970: 2_000)
        for i in 0..<8 {
            bookSeries.save(
                Sample(
                    time: t0.addingTimeInterval(Double(i) * 0.25), cpu: Double(i * 10), main: 5,
                    images: 30, missed: i, longestMs: Double(i * 20), jankMs: 3,
                    storageMB: 100 + Double(i),
                    freeMB: nil, thermal: "normal", place: "Reader", spot: "S. \(i)", scroll: "Finger",
                    builds: 2,
                    level: ["Lader": i], networkRunning: i, networkDone: 1, networkBytes: 1024,
                    networkFirstByteMs: 10,
                    networkFirstByteMaxMs: 20, networkAborts: 0, networkError: 0, networkPath: "WLAN",
                    tickMicros: 40))
        }
        #expect(bookSeries.all.count == 8)
        let seconds = TimeSeries.perSecond(bookSeries.all)
        #expect(seconds.count == 2)
        #expect(seconds[0].cpu == 15)
        #expect(seconds[0].images == 120)
        #expect(seconds[0].longestMs == 60)
        #expect(seconds[0].storageMB == 103)
        #expect(seconds[0].spot == "S. 3")
        #expect(seconds[1].networkDone == 4)
        #expect(seconds[1].networkBytes == 4096)
        let line = TimeSeries.line(seconds[1])
        #expect(line.contains("CPU  55 %"))
        #expect(line.contains("Lader 7"))
        #expect(line.contains("Network 7 running, 4 done, 4 KB"))
        #expect(line.contains("WLAN"))
        let csv = TimeSeries.csv(bookSeries.all)
        #expect(csv.hasPrefix(TimeSeries.csvHeader + "\n"))
        #expect(csv.split(separator: "\n").count == 9)
        #expect(csv.contains(";Lader=3;"))
    }

    @Test("Network requests: path kind without identifiers, network path as a word")
    func network() {
        #expect(NetworkRequest.kind(path: "/api/v1/books/0ABC/pages/17") == "Page")
        #expect(NetworkRequest.kind(path: "/api/v1/series/0ABC/thumbnail") == "Cover")
        #expect(NetworkRequest.kind(path: "/api/v1/books/0ABC/file") == "File")
        #expect(NetworkRequest.kind(path: "/api/v1/books") == "API")
        #expect(NetworkRequest.kind(path: "/dav/files/x/buch.epub") == "File")
        let a = NetworkRequest(
            time: Date(), host: "comics.example", kind: "Page", method: "GET", waitMs: 5,
            connectionMs: nil,
            firstByteMs: 180, transferMs: 40, totalMs: 230, bytes: 112 * 1024, log: "h2",
            reused: true, status: 200, failure: nil, cancelled: false)
        #expect(
            a.text
                == "comics.example · Page 200 h2 112 KB: Wait 5 ms, 1st byte 180 ms, Transfer 40 ms, total 230 ms"
        )
        #expect(a.csvRow.contains(";comics.example;Page;GET;5.0;;180.0;40.0;230.0;114688;h2;1;200;;0"))
        var last = NetworkLoad()
        last.save(a)
        var abort = a
        abort.cancelled = true
        abort.failure = "abgebrochen"
        last.save(abort)
        #expect(last.done == 2)
        #expect(last.aborts == 1)
        #expect(last.firstByteMedian == 180)
        #expect(
            NetworkPathWatch.text(
                status: .satisfied, interfaces: [.other, .wifi], names: ["utun3", "en0"], expensive: false,
                sparing: false) == "Wi-Fi + Tunnel")
        #expect(
            NetworkPathWatch.text(
                status: .satisfied, interfaces: [.other], names: ["utun3"], expensive: false, sparing: false)
                == "no network")
        #expect(
            NetworkPathWatch.text(
                status: .satisfied, interfaces: [.cellular], names: ["pdp_ip0"], expensive: true,
                sparing: true)
                == "Cellular (expensive, constrained)")
    }

    @Test("The report puts hangs, stack locations, storms and the timeline before the log")
    func report() {
        let t0 = Date(timeIntervalSince1970: 3_000)
        let stack =
            "\n      Akari  Leser.body +12\n      SwiftUI  AG::Graph +8\n      Akari  Leser.body +12"
        let e = [
            Event(time: t0, kind: .hang, place: "Start", text: "Main thread blocked 120 ms" + stack),
            Event(
                time: t0.addingTimeInterval(10), kind: .hang, place: "Comic reader",
                text: "Main thread blocked 1840 ms (heavy)" + stack),
            Event(time: t0.addingTimeInterval(11), kind: .sustainedLoad, place: "Start", text: "CPU Ø 98 %"),
            Event(
                time: t0.addingTimeInterval(40), kind: .longImages, place: "Comic reader · S. 5",
                text: "4 frames ≥ 50 ms in 1.2 s, longest 142 ms"),
        ]
        let points = (0..<200).map { i in
            Sample(
                time: t0.addingTimeInterval(Double(i) * 0.25), cpu: 20, main: 10, images: 30, missed: 0,
                longestMs: 9, jankMs: 1, storageMB: 150, freeMB: 1_000, thermal: "normal",
                place: "Comic reader",
                spot: "S. 5", scroll: "", builds: 0, level: [:], tickMicros: 30)
        }
        let text = ReportText.build(
            edition: "0.1.0 (376)", device: "iPad", recording: true, events: e, metrics: [],
            points: points,
            requests: 3)
        let hang = try! #require(
            text.range(of: "== Hangs (main thread blocked ≥ 100 ms): 2, of which ≥ 250 ms: 1"))
        let longest = try! #require(text.range(of: "1840 ms  Comic reader"))
        let spots = try! #require(text.range(of: "×2  Akari  Leser.body +12"))
        let storms = try! #require(
            text.range(of: "== Long frames (single frames ≥ 50 ms, as storms): 1"))
        let timelineLines = try! #require(text.range(of: "== Timeline around the heaviest events"))
        let log = try! #require(text.range(of: "== Log"))
        #expect(hang.lowerBound < longest.lowerBound)
        #expect(longest.lowerBound < spots.lowerBound)
        #expect(spots.lowerBound < storms.lowerBound)
        #expect(storms.lowerBound < timelineLines.lowerBound)
        #expect(timelineLines.lowerBound < log.lowerBound)
        #expect(text.contains("== Sustained load (CPU avg ≥ 40 % over a window): 1"))
        #expect(text.contains("Time series: 200 points every 250 ms, 0:49 min"))
        #expect(text.contains("Akari-Requests-….csv (3 requests)"))
        #expect(text.contains("▶ haenger: Comic reader — Main thread blocked 1840 ms (heavy)"))
        #expect(
            !text.contains("▶ haenger: Comic reader — Main thread blocked 1840 ms (heavy)\n      Akari")
        )
        #expect(text.contains("CPU  20 % · Main  10 % · Frames 120"))
        #expect(ReportText.duration(e[1]) == 1840)
        #expect(ReportText.longestOf(e[3]) == 142)
        // Hangs at 0 s and 10 s are ±5 s apart: one section, not two.
        #expect(ReportText.merged([(0, 5), (5, 15), (35, 45)]).count == 2)
        #expect(text.components(separatedBy: "\n-- ").count == 3)
    }
}
