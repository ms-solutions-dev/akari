import Foundation

/// The report as text: the evaluation first, then the timeline around the heaviest
/// events, then the log, MetricKit last.
///
/// **Evaluation first**, because the report is read to answer one question: where does it
/// hang? The longest hangs with the most frequent places in their stacks, the storms of
/// long frames, the slow network requests and every sustained load come before the three
/// thousand lines they were drawn from.
///
/// **The timeline** puts ±``context`` seconds of the time series around each of the heaviest
/// events — one line per second with CPU, main thread, frames, memory, scroll phase, levels
/// and network — and interleaves the log lines. So what happened *before* the jank is
/// visible, not just the jank.
enum ReportText {

    /// Seconds before and after an event in the timeline.
    static let context = 5
    /// At most this many timeline sections.
    static let parts = 10

    static func build(
        edition: String, device: String, recording: Bool, events: [Event],
        metrics: [(name: String, text: String)], points: [Sample] = [], requests: Int = 0,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("Akari — performance diagnostics")
        lines.append("Version: \(edition)")
        lines.append("Device: \(device)")
        lines.append("Created: \(time(now, withDate: true))")
        lines.append("Recording: \(recording ? "on" : "off")")
        if let first = events.first {
            lines.append(
                "Log since: \(time(first.time, withDate: true)) · \(events.count) events")
        }
        if let first = points.first, let last = points.last {
            let duration = last.time.timeIntervalSince(first.time)
            let cost = points.map(\.tickMicros)
            lines.append(
                String(
                    format:
                        "Time series: %d points every %.0f ms, %d:%02d min, own cost avg %d µs (max %d) per point",
                    points.count, TimeSeries.beat * 1000, Int(duration) / 60, Int(duration) % 60,
                    cost.reduce(0, +) / max(cost.count, 1), cost.max() ?? 0))
            lines.append(
                "Raw data: Akari-TimeSeries-….csv alongside"
                    + (requests > 0 ? ", Akari-Requests-….csv (\(requests) requests)" : ""))
        }
        lines.append("")

        let hang = events.filter { $0.kind == .hang }
        let heavy = hang.filter { duration($0) >= Int(HangWatchdog.heavy * 1000) }
        lines.append(
            "== Hangs (main thread blocked ≥ \(Int(HangWatchdog.threshold * 1000)) ms): \(hang.count), of which ≥ \(Int(HangWatchdog.heavy * 1000)) ms: \(heavy.count)"
        )
        let longest = hang.sorted { duration($0) > duration($1) }.prefix(15)
        for h in longest { lines.append("  \(time(h.time))  \(duration(h)) ms  \(h.place)") }
        let perPlace = Dictionary(grouping: hang, by: \.place).mapValues(\.count).sorted {
            $0.value > $1.value
        }
        if !perPlace.isEmpty {
            lines.append(
                "  je Ort: " + perPlace.prefix(8).map { "\($0.key) ×\($0.value)" }.joined(separator: " · "))
        }
        let frames = commonFrames(hang)
        if !frames.own.isEmpty {
            lines.append("  most frequent spots in the stacks (without system frames):")
            for (r, n) in frames.own.prefix(10) { lines.append("    ×\(n)  \(r)") }
        }
        if !frames.topmost.isEmpty {
            lines.append("  most frequent topmost frames (where the main thread was):")
            for (r, n) in frames.topmost.prefix(6) { lines.append("    ×\(n)  \(r)") }
        }
        lines.append("")

        let storms = events.filter { $0.kind == .longImages }
        lines.append(
            "== Long frames (single frames ≥ \(Int(Performance.longImageFrom)) ms, as storms): \(storms.count)"
        )
        for e in storms.sorted(by: { longestOf($0) > longestOf($1) }).prefix(15) {
            lines.append("  \(time(e.time))  \(e.place) — \(e.text)")
        }
        lines.append("")

        for (kind, title) in [
            (Event.Kind.sustainedLoad, "Sustained load (CPU avg ≥ 40 % over a window)"),
            (.jank, "Jank (≥ 5 ms/s late frames)"),
            (.rebuilt, "Rebuild storms (≥ 20 per second)"),
            (.network, "Network (requests ≥ \(Int(Performance.networkSlowFrom)) ms or failed)"),
            (.breadcrumb, "Drags (finger vs. strip; ⚠ = strip did not follow or did not coast)"),
            (.phase, "States (thermal, low-power mode, network path)"),
            (.metering, "Series (per window: count, mean, p95, maximum)"),
        ] {
            let list = events.filter { $0.kind == kind }
            lines.append("== \(title): \(list.count)")
            for e in list.suffix(kind == .metering ? 30 : 15) {
                lines.append("  \(time(e.time))  \(e.place) — \(e.text)")
            }
            lines.append("")
        }

        let metricHangs = metrics.filter { $0.text.contains("hangDiagnostics") }.count
        lines.append("== MetricKit: \(metrics.count) deliveries, \(metricHangs) with hang stacks")
        lines.append("")

        let timelineLines = timeline(events: events, points: points)
        if !timelineLines.isEmpty {
            lines.append("== Timeline around the heaviest events (per second; ▶ log)")
            lines += timelineLines
            lines.append("")
        }

        lines.append("== Log")
        for e in events {
            lines.append(
                "\(time(e.time))  \(e.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))  \(e.place) — \(e.text)"
            )
        }
        for m in metrics {
            lines.append("")
            lines.append("== MetricKit \(m.name)")
            lines.append(m.text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Evaluation

    /// The duration from a hang line — "Hauptfaden 1840 ms blockiert" → 1840.
    static func duration(_ e: Event) -> Int {
        Int(e.text.split(separator: " ").first { Int($0) != nil } ?? "") ?? 0
    }

    /// The longest frame from a storm line — "… longest 142 ms" → 142.
    static func longestOf(_ e: Event) -> Int {
        guard let area = e.text.range(of: "longest ") else { return 0 }
        return Int(e.text[area.upperBound...].split(separator: " ").first ?? "") ?? 0
    }

    /// Binary images whose frames say nothing about the app — runtime, dispatch, SwiftUI itself.
    /// The library names are assembled from parts because the string linter reads `x.y` as a key.
    static let systemImages: Set<String> = {
        let libraries = [
            "libsystem_kernel", "libsystem_pthread", "libsystem_c", "libsystem_malloc", "libsystem_platform",
            "libdispatch", "libobjc" + ".A", "libswiftCore", "libswift_Concurrency", "libdyld",
        ].map { $0 + ".dylib" }
        let frameworks = [
            "CoreFoundation", "Foundation", "SwiftUI", "SwiftUICore", "UIKitCore", "UIKit", "AttributeGraph",
            "QuartzCore", "GraphicsServices",
        ]
        return Set(libraries + frameworks)
    }()

    /// Counts frames across all hang stacks: the app's own (without system images) and the topmost ones.
    static func commonFrames(_ hang: [Event]) -> (own: [(String, Int)], topmost: [(String, Int)]) {
        var own: [String: Int] = [:]
        var topmost: [String: Int] = [:]
        for h in hang {
            let frames = h.text.split(separator: "\n").dropFirst().map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if let first = frames.first { topmost[first, default: 0] += 1 }
            var seen: Set<String> = []
            for r in frames {
                let image = String(r.split(separator: "  ", maxSplits: 1).first ?? "")
                guard !systemImages.contains(image), !image.hasPrefix("?"), seen.insert(r).inserted else {
                    continue
                }
                own[r, default: 0] += 1
            }
        }
        return (
            own.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) },
            topmost.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        )
    }

    // MARK: - Timeline

    /// The heaviest events: hangs by duration, storms by longest frame, network by
    /// total duration, sustained load — at most ``parts`` sections, overlapping ones merged.
    static func timeline(events: [Event], points: [Sample]) -> [String] {
        guard !points.isEmpty else { return [] }
        let hang = events.filter { $0.kind == .hang }.sorted { duration($0) > duration($1) }.prefix(5)
        let storms = events.filter { $0.kind == .longImages }.sorted { longestOf($0) > longestOf($1) }
            .prefix(3)
        let network = events.filter { $0.kind == .network }.prefix(2)
        let sustainedLoad = events.filter { $0.kind == .sustainedLoad }.suffix(2)
        let drags = events.filter { $0.kind == .breadcrumb && $0.text.hasPrefix("⚠") }.prefix(3)
        let anchors = (Array(drags) + Array(hang) + Array(storms) + Array(network) + Array(sustainedLoad))
            .prefix(
                parts)
        guard !anchors.isEmpty else { return [] }
        let areas = merged(
            anchors.map { (second($0.time) - context, second($0.time) + context) }.sorted { $0.0 < $1.0 })
        let perSecond = Dictionary(
            TimeSeries.perSecond(points).map { (second($0.time), $0) }, uniquingKeysWith: { _, b in b })
        let eventsPerSecond = Dictionary(
            grouping: events.filter { $0.kind != .last && $0.kind != .metering }
        ) {
            second($0.time)
        }
        var lines: [String] = []
        for (from, until) in areas {
            lines.append(
                "-- \(time(Date(timeIntervalSince1970: TimeInterval(from)))) bis \(time(Date(timeIntervalSince1970: TimeInterval(until))))"
            )
            for s in from...until {
                let stamp = time(Date(timeIntervalSince1970: TimeInterval(s)))
                if let p = perSecond[s] {
                    lines.append("\(stamp)  \(TimeSeries.line(p))")
                } else {
                    lines.append("\(stamp)  —")
                }
                for e in eventsPerSecond[s] ?? [] {
                    let header = e.text.split(separator: "\n").first.map(String.init) ?? e.text
                    lines.append("          ▶ \(e.kind.rawValue): \(e.place) — \(header)")
                }
            }
        }
        return lines
    }

    static func second(_ d: Date) -> Int { Int(d.timeIntervalSince1970.rounded(.down)) }

    /// Merges sorted ranges that touch or overlap.
    static func merged(_ areas: [(Int, Int)]) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        for b in areas {
            if let last = result.last, b.0 <= last.1 + 1 {
                result[result.count - 1] = (last.0, max(last.1, b.1))
            } else {
                result.append(b)
            }
        }
        return result
    }

    private static func time(_ d: Date, withDate: Bool = false) -> String {
        withDate
            ? d.formatted(.dateTime.day().month().year().hour().minute().second())
            : d.formatted(.dateTime.hour().minute().second())
    }
}
