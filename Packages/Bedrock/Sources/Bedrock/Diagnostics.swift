import Foundation
import OSLog
import Synchronization

/// Logging that actually helps when something fails.
///
/// Nobody can read logs on a television, and a message like "No response" does
/// not reveal whether the address was wrong, the system refused the connection
/// from the start, or the server stayed silent. So every attempt is recorded with
/// **address, result and cause**, and the cause is translated into plain text
/// instead of leaving only a number.
///
/// Read it with (the subsystem is the bundle identifier, see ``ProgramID``):
/// ```
/// xcrun simctl spawn booted log show --predicate 'subsystem == "<bundle identifier>"'
/// ```
///
/// **What lives here and what does not:** network requests, flow trace, ring
/// buffer, profile and the redaction rules apply to every program. The playback
/// and focus traces know about video and remote control and therefore live as
/// extensions in the host app.
public enum Diagnostics {

    public static let network = Logger(
        subsystem: ProgramID.bundle,
        category: "network"
    )

    /// The course of an operation: its own trace, kept apart from the network requests.
    ///
    /// **Why separate:** an operation rarely fails with an error. It fails because
    /// something does not happen: a state that does not arrive, a seek that expires,
    /// a buffer that never fills. That is only visible in the **order and the
    /// intervals**, and those get lost between server requests. Together in one
    /// trace the flow reads like a log; scattered it is unreadable.
    ///
    /// In the host app the same trace is called ``playback``, because there the
    /// operation is a playback. The category stays `playback`, so `log.sh` and the
    /// evaluations keep working.
    public static let flow = Logger(
        subsystem: ProgramID.bundle,
        category: "playback"
    )

    /// Records a step of the operation, with the time since its start.
    ///
    /// The time is the actual information here and not an accessory: that a seek
    /// went out 0.6 seconds after loading was the whole bug. The message alone
    /// showed nothing, only the distance to the line above did.
    ///
    /// - Parameter area: How the trace entry names the operation, "Playback" in the
    ///   television app, "Reading" in the reading app.
    public static func step(_ step: String, since start: Date?, area: String = "Flow") {
        flow.info("\(elapsed(since: start), privacy: .public) \(step, privacy: .public)")
        if let entry = verboseEntry(step, failed: false, area: area) {
            Task { @MainActor in Trace.record(entry) }
        }
    }

    /// Like ``step(_:since:area:)``, but as an error, so it is visible without `--info`.
    ///
    /// The difference matters in practice: `log show` shows only errors without
    /// further action. An anomaly filed as `info` is found only by whoever is
    /// already looking for it.
    public static func deficiency(_ step: String, since start: Date?, area: String = "Flow") {
        flow.error("\(elapsed(since: start), privacy: .public) \(step, privacy: .public)")
        if let entry = verboseEntry(step, failed: true, area: area) {
            Task { @MainActor in Trace.record(entry) }
        }
    }

    /// Like ``deficiency(_:since:area:)``, but with the error itself, **and a
    /// cancellation is not a deficiency**.
    ///
    /// The cause comes from ``explain(_:)`` and follows the step. If the error is a
    /// cancellation (``isCancellation(_:)``), the line goes only into the verbose
    /// recording: a request nobody waits for any more did nothing wrong.
    public static func deficiency(
        _ step: String, failure: any Error, since start: Date?, area: String = "Flow"
    ) {
        guard let sentence = deficiencySentence(step, failure: failure) else {
            verbose("\(step): cancelled", since: start, area: area)
            return
        }
        deficiency(sentence, since: start, area: area)
    }

    /// The sentence for a deficiency with an error, `nil` for a cancellation. A pure
    /// computation, so it can be tested without the shared trace.
    static func deficiencySentence(_ step: String, failure: any Error) -> String? {
        isCancellation(failure) ? nil : "\(step): \(explain(failure))"
    }

    /// Whether an error only says that nobody waits for the answer any more:
    /// `URLError.cancelled` (-999), a `CancellationError`, or the same as an `NSError`.
    ///
    /// **The finding:** the always-on error log contained "Fetch ratings ✗ network
    /// error -999" seven times per scroll: whoever scrolls on quickly cancels the
    /// requests of the previous tiles, and that is intended. Red lines for the normal
    /// case soon stop being read, and then so does the one that matters.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError { return url.code == .cancelled }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// Records a step only with verbose recording.
    ///
    /// For the places that would be too much in normal operation: every buffer
    /// message, every seek decision, every URL built. They are exactly what is
    /// missing when hunting for a stutter, and exactly what would drown a
    /// fifty-slot trace in everyday use. The switch for it is in the settings under
    /// "Diagnostics", see ``DebugMode``.
    ///
    /// `@autoclosure`, so the text is not even built in the normal case; these calls
    /// sit in the rhythm of the operation.
    ///
    /// `area` deliberately has no default value: the host app adds a two-parameter
    /// `verbose(_:since:)` next to it, and two overloads that both fit the same call
    /// would be an ambiguity waiting to happen.
    public static func verbose(
        _ message: @autoclosure () -> String, since start: Date? = nil, area: String
    ) {
        guard DebugMode.current.isOn else { return }
        step(message(), since: start, area: area)
    }

    /// The trace entry for a playback step, or `nil` if none belongs in it.
    ///
    /// **The one rule of the whole logging:** an **error** ALWAYS belongs in the
    /// trace. A diagnosis that records the error only if someone flipped a switch
    /// beforehand is empty for the real error. An ordinary **step**, on the other
    /// hand, is in there only with verbose recording: in everyday use it would
    /// displace the errors the trace exists for. The system log contains both always.
    /// Extracted as its own function so the rule can be tested without waiting for
    /// the detached entry task.
    static func verboseEntry(
        _ text: String,
        failed: Bool,
        enabled: Bool = DebugMode.current.isOn,
        area: String = "Flow"
    ) -> Trace.Entry? {
        guard enabled || failed else { return nil }
        return Trace.Entry(
            at: Date(),
            step: area,
            target: failed ? "" : text,
            outcome: failed ? .failed(text) : .succeeded("")
        )
    }

    /// Below this limit `[%5.1fs]` renders only `0.0` anyway.
    ///
    /// The limit is thus tied to the resolution of the field and not to an opinion
    /// about what is fast.
    static let elapsedResolution: TimeInterval = 0.05

    /// The time since a reference point, as a fixed-width field.
    ///
    /// **Without information, no acquittal, even for your own timestamp.** Whoever
    /// passes `since: Date()` fetches the reference point at the moment of reporting
    /// and gets a zero nobody measured. Three renderings, each with exactly one
    /// meaning:
    ///
    /// - `[  —  ]`: no usable reference point: none passed, or one that lies after
    ///   the report.
    /// - `[ <0.1s]`: measured, but below the resolution of the field.
    /// - `[ 12.3s]`: a span worth talking about.
    ///
    /// A dash and a zero must not look alike; otherwise a missing reference point
    /// reads like a lightning-fast step.
    ///
    /// `now` is passed in so the function can be tested at all. The reach is
    /// limited: the field appears only in the line for the system log, never in the
    /// trace entry and so never in the uploaded report.
    static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "[  —  ]" }
        let seconds = now.timeIntervalSince(start)
        guard seconds >= 0 else { return "[  —  ]" }
        guard seconds >= elapsedResolution else { return "[ <0.1s]" }
        return String(format: "[%5.1fs]", seconds)
    }

    /// The latest messages, for display **on the television**.
    ///
    /// **Because nobody can get at a log there.** On a computer `log show` is
    /// enough; on the Apple TV it is not: over the network macOS refuses to collect
    /// ("Device not configured"), and with a cable you are standing in the living
    /// room. Exactly then you need it: an error that occurs only on the television
    /// can otherwise only be guessed at.
    ///
    /// A fixed-length ring buffer and nothing more: it should carry the latest
    /// troubleshooting, not keep an operations journal. Whatever is older no longer
    /// helps and would only hold memory.
    @MainActor
    public enum Trace {

        /// An entry as it appears in the settings.
        public struct Entry: Identifiable, Sendable, Equatable {
            public let id = UUID()
            public let at: Date
            public let step: String
            /// The address, already without credentials, see ``Diagnostics/loggable(_:)``.
            public let target: String
            public let outcome: Outcome

            /// Public so the extensions in the host app (playback and focus traces) can
            /// build their entries themselves.
            public init(at: Date, step: String, target: String, outcome: Outcome) {
                self.at = at
                self.step = step
                self.target = target
                self.outcome = outcome
            }

            public enum Outcome: Sendable, Equatable {
                case started
                case succeeded(String)
                /// The translated cause, not the error number.
                case failed(String)
            }

            /// The line as it appears in report and disk trace, without a timestamp, which
            /// ``TraceRecorder`` sets when appending.
            ///
            /// Here and not in the report: the report now reads the file, and two
            /// formattings of the same entry would drift apart.
            public var reportLine: String {
                let mark: String
                switch outcome {
                case .started: mark = "→"
                case .succeeded(let detail): mark = detail.isEmpty ? "✓" : "✓ \(detail)"
                case .failed(let reason): mark = "✗ \(reason)"
                }
                return "\(step)  \(target)  \(mark)"
            }
        }

        /// How many entries are kept.
        ///
        /// Fifty cover a sign-in attempt with everything attached several times over.
        /// More could not be read on a television anyway.
        public static let capacity = 50

        /// How many there are with verbose recording.
        ///
        /// Fifty would be full there within seconds: every successful request and every
        /// playback step is added, and the very line for which the switch was flipped
        /// would fall out the back. Two hundred carry a whole playback test. Such a
        /// trace is not read on the television anyway, but in the uploaded report.
        public static let verboseCapacity = 200

        /// The limit currently in force; it follows the switch.
        static var currentCapacity: Int {
            DebugMode.current.isOn ? verboseCapacity : capacity
        }

        public private(set) static var entries: [Entry] = []

        /// The entries in chronological order, for display and report.
        ///
        /// **Not the same as ``entries``.** Entries are made through detached tasks, and
        /// nobody promises their order: two almost simultaneous messages can arrive
        /// swapped. Whoever outputs the raw list then shows an "after" before its
        /// "before", and every troubleshooting here depends on exactly such intervals.
        /// For output the clock counts, not the luck of the queue.
        public static var chronological: [Entry] {
            entries.sorted { $0.at < $1.at }
        }

        /// Appends an entry, also for the extensions in the host app (playback and
        /// focus traces), hence public.
        public static func record(_ entry: Entry) {
            entries.append(entry)
            if entries.count > currentCapacity {
                entries.removeFirst(entries.count - currentCapacity)
            }
            // To disk, **separated by kind**: errors into the error trace, which always
            // runs, so the report carries them even if nobody ever flipped a switch. Every
            // line goes into the recording (the error too, because the context belongs
            // there), but only while the switch is on. Rolling and limited; the rules are
            // at ``TraceRecorder``.
            let line = entry.reportLine
            let at = entry.at
            let isFailure = if case .failed = entry.outcome { true } else { false }
            let isRecording = DebugMode.current.isOn
            Task.detached(priority: .utility) {
                if isFailure { await TraceRecorder.errors.append(line, at: at) }
                if isRecording { await TraceRecorder.shared.append(line, at: at) }
            }
        }

        public static func clear() {
            entries = []
        }
    }

    /// Enters a message into the trace that is readable on the television.
    ///
    /// Separate from the system log and in addition to it: one is for the
    /// computer, the other for the living room.
    private static func trace(
        _ url: URL,
        step: String,
        outcome: Trace.Entry.Outcome
    ) {
        let entry = Trace.Entry(
            at: Date(),
            step: step,
            target: loggable(url),
            outcome: outcome
        )
        Task { @MainActor in Trace.record(entry) }
    }

    /// The profile for the head of a submitted diagnosis.
    ///
    /// **A trace without a build state is half a trace:** every evaluation started
    /// with the question whether the finding comes from the new or the old build,
    /// and the answer was nowhere. The build time is the actual identifier: the
    /// version number does not change between two test builds on the same day, the
    /// timestamp of the program file always does.
    ///
    /// - Parameter extra: Lines only a particular program knows. The host app
    ///   appends engine and decoder here, the reading app nothing.
    public static func reportHeader(extra: [String]) -> [String] {
        let bundle = Bundle.main
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var built = "unknown"
        if let executable = bundle.executableURL,
            let date = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
        {
            built = date.formatted(date: .abbreviated, time: .standard)
        }

        var uts = utsname()
        uname(&uts)
        let model = withUnsafeBytes(of: &uts.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        return [
            "Version: \(version) (build \(build)), built \(built)",
            "Device: \(model), \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Debug mode: \(DebugMode.current.isOn ? "on" : "off")",
        ] + extra
    }

    /// Writes the state marker into both traces; to be called at app launch.
    ///
    /// **Without it a trace spanning several days cannot be attributed:** the files
    /// hold three days and thus several builds; only the marker in between says which
    /// entry belongs to which build.
    public static func noteLaunch(extra: [String]) {
        let line = "— App-Start · " + reportHeader(extra: extra).joined(separator: " · ") + " —"
        Task.detached(priority: .utility) {
            await TraceRecorder.errors.append(line)
            await TraceRecorder.shared.append(line)
        }
        // **The crash of the previous run, right behind the state marker,** as a
        // deficiency, so it is in the error trace and travels to the server with the
        // diagnosis. Rationale at ``CrashGuard``.
        if let report = CrashGuard.takePreviousReport() {
            let (head, frames) = CrashGuard.lines(from: report)
            deficiency("Crash in the previous run: \(head)", since: nil)
            if !frames.isEmpty { deficiency("Call chain: \(frames)", since: nil) }
        }
    }

    /// Writes the switch change into the recording.
    ///
    /// So a trace with a gap does not look like an error: between "switched off"
    /// and "switched on" the silence has an explanation.
    public static func noteRecordingSwitch(isOn: Bool) {
        let line = "— recording switched \(isOn ? "on" : "off") —"
        Task.detached(priority: .utility) {
            await TraceRecorder.shared.append(line)
        }
    }

    /// Records a connection attempt.
    ///
    /// **In the trace only with verbose recording.** The rule is at
    /// ``verboseEntry(_:failed:enabled:)``: successes and beginnings are recording,
    /// not error history. In the system log it is always there.
    public static func attempt(_ url: URL, step: String) {
        network.info("→ \(step, privacy: .public): \(loggable(url), privacy: .public)")
        guard DebugMode.current.isOn else { return }
        trace(url, step: step, outcome: .started)
    }

    public static func success(_ url: URL, step: String, detail: String = "") {
        network.info(
            "✓ \(step, privacy: .public): \(loggable(url), privacy: .public) \(detail, privacy: .public)"
        )
        guard DebugMode.current.isOn else { return }
        trace(url, step: step, outcome: .succeeded(detail))
    }

    /// What is known about the **connection**, not about the request.
    ///
    /// **That is the difference between knowing and guessing.** A timeout only says
    /// that no response came. It does not say whether a connection came about at all,
    /// whether an existing one was reused, and whether data flowed. A troubleshooting
    /// session got stuck on exactly that: the same request takes 50 milliseconds from
    /// the computer and runs into the timeout twice from the television. With these
    /// numbers that can be told apart; without them it is a guess.
    ///
    /// The suspicion for which they are collected: tvOS releases network connections
    /// when an app goes to the background ("socket resource reclaim", TN2277) but
    /// still remembers the socket. The next request on it then hangs until the
    /// timeout, without an error message. If ``reused`` is true on a failure and
    /// ``connectDuration`` is empty, that is exactly what happened.
    public struct ConnectionFacts: Sendable, Equatable {
        /// Whether an existing connection was used.
        public let reused: Bool
        /// `http/1.1`, `h2`, depending on what was negotiated.
        public let networkProtocol: String?
        /// The remote end as actually reached. Reveals, among other things, whether
        /// IPv6 was used.
        public let remoteAddress: String?
        /// How long establishing the connection took. Empty when reused.
        public let connectDuration: TimeInterval?
        /// How long it took to the first byte of the response.
        public let timeToFirstByte: TimeInterval?
        public let bytes: Int64

        public init(
            reused: Bool,
            networkProtocol: String?,
            remoteAddress: String?,
            connectDuration: TimeInterval?,
            timeToFirstByte: TimeInterval?,
            bytes: Int64
        ) {
            self.reused = reused
            self.networkProtocol = networkProtocol
            self.remoteAddress = remoteAddress
            self.connectDuration = connectDuration
            self.timeToFirstByte = timeToFirstByte
            self.bytes = bytes
        }

        /// A line that is readable on the television.
        public var summary: String {
            var parts: [String] = [reused ? "connection reused" : "new connection"]
            if let networkProtocol { parts.append(networkProtocol) }
            if let connectDuration {
                parts.append("setup \(Self.millis(connectDuration))")
            }
            if let timeToFirstByte {
                parts.append("first byte after \(Self.millis(timeToFirstByte))")
            } else {
                // The most important case, hence spelled out: nothing ever came back. An empty
                // field would look like "not measured" here.
                parts.append("no response received")
            }
            if bytes > 0 { parts.append("\(bytes) bytes") }
            return parts.joined(separator: ", ")
        }

        static func millis(_ seconds: TimeInterval) -> String {
            seconds < 1
                ? "\(Int(seconds * 1000)) ms"
                : String(format: "%.1f s", seconds)
        }
    }

    /// Records how a connection came about, regardless of whether the request
    /// succeeded.
    ///
    /// **Not every** request is recorded: a home screen triggers dozens, and fifty
    /// entries would be full after the first screen build. What is recorded is what
    /// stands out: a failure, or a request that stood unusually long.
    public static func connection(_ url: URL, step: String, facts: ConnectionFacts) {
        network.info(
            "◇ \(step, privacy: .public): \(loggable(url), privacy: .public) — \(facts.summary, privacy: .public)"
        )
        guard DebugMode.current.isOn else { return }
        trace(url, step: step, outcome: .succeeded(facts.summary))
    }

    /// How a measurement turned out.
    ///
    /// **Because a deficiency could not be filed at all.** Every measurement went
    /// into the trace as a success; one session produced 579 measurements and not a
    /// single error line, despite dropouts and 415 s of drift. A named outcome
    /// instead of a Boolean reads as a statement at the call site:
    /// `probe(text, verdict: .problem)`.
    public enum ProbeVerdict: Sendable, Equatable {
        /// Figures without a deficiency.
        case plain
        /// The measurement names a deficiency.
        case problem
    }

    /// Records the result of a measurement, of the connection or of a playback.
    ///
    /// Multi-line, unlike everything else in the trace: a measurement is not an
    /// event but a finding, and a finding cannot be squeezed into one line without
    /// leaving out exactly what was measured for.
    ///
    /// **A deficiency waits for no switch.** That is word for word the rule
    /// ``verboseEntry(_:failed:enabled:)`` already enforces: a diagnosis that knows
    /// the deficiency only with the switch flipped is empty for the real deficiency.
    /// Hence `.problem` goes out as an error, visible in `log show` without
    /// `--info`, and into the trace without a detour through ``DebugMode``.
    ///
    /// The logger deliberately stays ``network`` and not ``playback``, so existing
    /// evaluations and searches for `◆` keep working; only the level changed.
    @MainActor
    public static func probe(_ text: String, verdict: ProbeVerdict = .plain) {
        switch verdict {
        case .plain:
            network.info("◆ Measurement:\n\(text, privacy: .public)")
            guard DebugMode.current.isOn else { return }
            Trace.record(
                Trace.Entry(at: Date(), step: "Measurement", target: "", outcome: .succeeded(text))
            )
        case .problem:
            network.error("◆ Measurement — deficiency:\n\(text, privacy: .public)")
            Trace.record(
                Trace.Entry(at: Date(), step: "Measurement", target: "", outcome: .failed(text))
            )
        }
    }

    /// Records a failure, with the translated cause.
    ///
    /// **A cancellation is not a failure** (see ``isCancellation(_:)``): it appears
    /// in the system log as info and in the trace only with verbose recording, never
    /// in the always-on error log.
    public static func failure(_ url: URL, step: String, error: Error) {
        guard !isCancellation(error) else {
            network.info(
                "↺ \(step, privacy: .public): \(loggable(url), privacy: .public) — cancelled")
            if let outcome = traceOutcome(for: error) { trace(url, step: step, outcome: outcome) }
            return
        }
        let explained = explain(error)
        network.error(
            "✗ \(step, privacy: .public): \(loggable(url), privacy: .public) — \(explained, privacy: .public)"
        )
        trace(url, step: step, outcome: .failed(explained))
    }

    /// What a failure leaves in the trace, `nil` if nothing: a cancellation is
    /// in there only with verbose recording, and then not as a failure.
    static func traceOutcome(
        for error: any Error, recording: Bool = DebugMode.current.isOn
    ) -> Trace.Entry.Outcome? {
        guard isCancellation(error) else { return .failed(explain(error)) }
        return recording ? .succeeded("cancelled") : nil
    }

    /// The path sections behind which the credentials stand for an Xtream provider.
    ///
    /// **What is recognized is the shape, not the password.** Which part of a foreign
    /// address is the credential is unknown to this package, but where it sits is
    /// known: `XtreamEndpoint.streamURL` assembles every stream address as
    /// `/live|movie|series/USER/PASSWORD/ID[.ts]`.
    ///
    /// The lowercase spelling is intentional and no carelessness: the own media
    /// server uses `/LiveTv/…`, and that is not a provider address.
    private static let credentialCarryingSections: Set<String> = ["live", "movie", "series"]

    /// The address as it may go into the log: without query and without credentials
    /// in the address itself.
    ///
    /// **Why this is here and not at every caller:** IPTV addresses carry the
    /// credentials in the query throughout: `get.php?username=…&password=…` for the
    /// channel list, `xmltv.php?username=…&password=…` for the program guide.
    /// Whoever logs such an address in full writes the password in plain text into
    /// the system log, as `.public`, so into every error report somebody passes on.
    /// Providers block an account used from several places; the viewer then loses
    /// not one show but television altogether.
    ///
    /// At the individual caller this rule could not be kept: it would be forgotten
    /// as soon as a second place logged addresses. Here it applies to every caller,
    /// including the next.
    ///
    /// Decompose instead of search: searching for the password presupposes knowing
    /// it; with an M3U address the user enters as one whole line, nobody knows which
    /// part is the credential. What remains (host, port and path) suffices for the
    /// purpose: telling which request failed.
    ///
    /// **The path is the second place where the credentials stand.** The stream
    /// address of an Xtream provider has no query at all; there user and password
    /// sit between section and ID, see ``credentialCarryingSections``. Only this
    /// shape is masked, and the ID stays: without it one could no longer say which
    /// channel failed.
    public static func loggable(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // An address that cannot be decomposed is exactly the one where it is unclear
            // where the credentials sit. Better nothing then.
            return "(address not representable)"
        }

        parts.query = nil
        parts.fragment = nil
        // `http://user:secret@server/list.m3u` occurs: some providers hand out their
        // address like that.
        parts.user = nil
        parts.password = nil

        // The placeholders are deliberately ASCII capitals and not `•••`:
        // `URLComponents` encodes everything outside ASCII when assembling, so three
        // dots would become `%E2%80%A2%E2%80%A2%E2%80%A2` and the line would be
        // unreadable.
        //
        // Everything between section and ID is replaced, not just two fixed places:
        // `XtreamEndpoint` deliberately does NOT encode a slash in the password
        // (otherwise the server would not find the path), and the observed passwords
        // are doubly nested Base64, whose alphabet contains the slash. Such a password
        // yields more than five sections, and the rest would otherwise remain in the
        // log.
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.count >= 5, segments[0].isEmpty,
            credentialCarryingSections.contains(String(segments[1]))
        {
            let section = String(segments[1])
            let id = String(segments[segments.count - 1])
            parts.path = "/\(section)/USER/PASSWORD/\(id)"
        }

        return parts.url?.absoluteString ?? "(address not representable)"
    }

    /// How much foreign text may go into a line at most.
    public static let borrowedTextLimit = 160

    /// Passes on foreign text only if no address is in it.
    ///
    /// **Recognize the shape, do not look for the credential.** With an Xtream
    /// provider, user name and password stand in the PATH
    /// (`/live/USER/PASSWORD/ID.ts`). ``loggable(_:)`` covers this shape but can do
    /// so only for a `URL`; in foreign running text (`localizedDescription`, an
    /// `NSError` dump, a comment from the engine's error log) the address sits
    /// somewhere in the middle and cannot safely be cut out. Hence the hard rule
    /// here: where `://` occurs, the whole text does not go out. A past report is
    /// the proof that passed-through foreign text takes the credentials along in
    /// plain text.
    ///
    /// **Why here and not at the engine:** the rule once stood a second time in the
    /// playback engine because it was needed there and missing here: exactly the
    /// duplication the comment on ``loggable(_:)`` warns about. A rule that stands in
    /// two places gets forgotten in one of them.
    ///
    /// Smoothing the line breaks is a bonus and not a necessity:
    /// `TraceRecorder.append` already replaces `\n` with a space, so the submitted
    /// report does not fall apart. Two gaps remain, though: the trace display on the
    /// television does not smooth at all, and `\r` leaves a line standing while
    /// `isNewline` covers it.
    public static func withoutAddress(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard !text.contains("://") else { return "(contains an address — omitted)" }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > borrowedTextLimit else { return flat }
        return String(flat.prefix(borrowedTextLimit)) + "…"
    }

    /// Translates the usual network errors into a cause that can be worked with.
    /// The bare number forces a lookup every time, and -1022 in particular is
    /// regularly misread.
    public static func explain(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            // **The fallback is the silent side entrance.** What arrives here is foreign
            // text: for an `NSError` the whole dump including
            // `NSErrorFailingURLStringKey`, which carries the credentials in plain text.
            // Without this bolt, every switch from `String(describing:)` to `explain`
            // would only move the hole.
            return withoutAddress("\(error)") ?? "unknown error"
        }

        let cause: String =
            switch urlError.code {
            case .appTransportSecurityRequiresSecureConnection:
                """
                Das System hat die Verbindung verweigert, bevor sie aufgebaut wurde \
                (Transportsicherheit, -1022). Unverschlüsselte Verbindungen zu dieser \
                Adresse sind nicht erlaubt. Prüfen: Steht NSAllowsArbitraryLoads in der \
                Info.plist — und steht daneben KEIN NSAllowsLocalNetworking? Beide \
                zusammen heben sich auf.
                """
            case .cannotFindHost:
                "The name could not be resolved (-1003). Check: does the device use the home network's DNS?"
            case .cannotConnectToHost:
                "The machine answers, but nothing is listening on this port (-1004)."
            case .timedOut:
                "Timed out (-1001). The server was reachable, but too slow, or the connection dropped."
            case .notConnectedToInternet:
                "No network connection (-1009)."
            case .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                "The certificate is not trusted — typical for self-issued certificates."
            case .networkConnectionLost:
                "The connection dropped mid-transfer (-1005)."
            case .cancelled:
                "Cancelled (-999) — nobody was waiting for the answer any more."
            default:
                "Network error \(urlError.errorCode)"
            }

        return cause
    }
}
