import Foundation
import Testing

@testable import Bedrock

/// The switch for verbose recording, and the trace that hangs on it.
///
/// Serial, because ``DebugMode/current`` and the trace are globals: two tests
/// flipping them at the same time would test each other instead of the subject.
@Suite("Verbose recording and trace", .serialized)
struct DiagnosticsTraceTests {

    /// A plain entry with a selectable time.
    private func entry(_ step: String, at date: Date = Date()) -> Diagnostics.Trace.Entry {
        Diagnostics.Trace.Entry(at: date, step: step, target: "", outcome: .started)
    }

    @Test("The launch adopts the stored state of the switch")
    func activateLoadsStoredState() throws {
        // The bug this test stands against: the only writer of ``DebugMode/current`` was
        // the tap in the settings. After every restart the app recorded sparsely,
        // whatever the store said.
        let before = DebugMode.current
        defer { DebugMode.current = before }

        let store = InMemoryStore()
        DebugMode(isOn: true).save(to: store)
        DebugMode.activate(from: store)
        #expect(DebugMode.current.isOn)

        // And the opposite direction: an empty store means off, not "stays as it was".
        DebugMode.activate(from: InMemoryStore())
        #expect(!DebugMode.current.isOn)
    }

    /// **A trace without a build state is half a trace:** every submitted diagnosis
    /// should say, without asking back, which build, which device and which mode it
    /// comes from.
    @Test("The profile names build, device and mode")
    func reportHeaderCarriesTheEssentials() {
        let header = Diagnostics.reportHeader(extra: ["Regal: 3 Quellen"])

        #expect(header.count == 4)
        #expect(header[0].hasPrefix("Version: "))
        #expect(header[0].contains("built"))
        #expect(header[1].hasPrefix("Device: "))
        #expect(header[2].hasPrefix("Debug mode: "))
        // What only the program knows, it appends itself; the foundation lets the line
        // through without knowing it.
        #expect(header[3] == "Regal: 3 Quellen")
    }

    @Test("Steps follow the switch, errors do not")
    func verboseEntryFollowsTheSwitch() {
        // In normal operation the trace is reserved for errors; otherwise every beat of
        // the playback would displace exactly the lines it exists for.
        #expect(Diagnostics.verboseEntry("Sprung zu 90 s", failed: false, enabled: false) == nil)

        let step = Diagnostics.verboseEntry(
            "Sprung zu 90 s", failed: false, enabled: true, area: "Playback")
        #expect(step?.step == "Playback")
        #expect(step?.target == "Sprung zu 90 s")
        #expect(step?.outcome == .succeeded(""))

        // A problem carries its text as the cause, so the display shows it in red and in
        // full width, like any other failure.
        let problem = Diagnostics.verboseEntry("Strom abgerissen", failed: true, enabled: true)
        #expect(problem?.outcome == .failed("Strom abgerissen"))

        // **An error waits for no switch:** a diagnosis that knows the error only with
        // the switch flipped is empty for the real error.
        let alwaysThere = Diagnostics.verboseEntry("Strom abgerissen", failed: true, enabled: false)
        #expect(alwaysThere?.outcome == .failed("Strom abgerissen"))
    }

    @Test("The trace grows with the switch and shrinks with it")
    @MainActor
    func capacityFollowsTheSwitch() {
        let before = DebugMode.current
        defer {
            DebugMode.current = before
            Diagnostics.Trace.clear()
        }
        Diagnostics.Trace.clear()

        // Verbose: more than the fifty everyday slots; otherwise a single playback test
        // displaces itself before anybody uploads it.
        DebugMode.current = DebugMode(isOn: true)
        let overflow = Diagnostics.Trace.capacity + 10
        for i in 0..<overflow {
            Diagnostics.Trace.record(entry("Schritt \(i)"))
        }
        #expect(Diagnostics.Trace.entries.count == overflow)

        // Back to sparse: the next entry trims to the small limit.
        DebugMode.current = DebugMode(isOn: false)
        Diagnostics.Trace.record(entry("danach"))
        #expect(Diagnostics.Trace.entries.count == Diagnostics.Trace.capacity)
    }

    @Test("The output orders by the clock, not by the order of enqueueing")
    @MainActor
    func outputIsChronological() {
        defer { Diagnostics.Trace.clear() }
        Diagnostics.Trace.clear()

        // Deliberately enqueued the wrong way round: exactly how entries arrive when two
        // detached tasks overtake each other.
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        Diagnostics.Trace.record(entry("spät", at: base.addingTimeInterval(2)))
        Diagnostics.Trace.record(entry("früh", at: base))
        Diagnostics.Trace.record(entry("mittig", at: base.addingTimeInterval(1)))

        #expect(Diagnostics.Trace.chronological.map(\.step) == ["früh", "mittig", "spät"])
    }

    /// **A deficiency waits for no switch.** Until recently every measurement went
    /// into the trace as a success: 579 measurements in a session with dropouts, not
    /// a single error line. An outcome that can take only one value is no proof.
    @Test("A deficiency from a measurement is in the trace even without the switch flipped")
    @MainActor
    func probeReportsAProblemWithoutTheSwitch() {
        let before = DebugMode.current
        defer {
            DebugMode.current = before
            Diagnostics.Trace.clear()
        }
        Diagnostics.Trace.clear()
        DebugMode.current = DebugMode(isOn: false)

        // Figures without a deficiency hang on the switch; otherwise they would displace
        // in everyday use exactly the lines the trace exists for.
        Diagnostics.probe("Anlauf [native/direct]  bereit: 900 ms")
        #expect(Diagnostics.Trace.entries.isEmpty)

        Diagnostics.probe("14 Aussetzer, zusammen 23 s", verdict: .problem)
        #expect(Diagnostics.Trace.entries.count == 1)
        #expect(Diagnostics.Trace.entries[0].step == "Measurement")
        #expect(Diagnostics.Trace.entries[0].outcome == .failed("14 Aussetzer, zusammen 23 s"))
    }

    /// **The timestamp is the actual information, not an accessory.** Whoever passes
    /// `since: Date()` fetches the reference point at the moment of reporting; the
    /// zero in it is computed and not measured. Each of the three renderings should
    /// say exactly one thing.
    @Test("A start time from the same instant yields no zero")
    func elapsedTellsTheThreeCasesApart() {
        let now = Date(timeIntervalSince1970: 5_000)

        // No reference point, and a reference point from the future is none either.
        #expect(Diagnostics.elapsed(since: nil, now: now) == "[  —  ]")
        #expect(Diagnostics.elapsed(since: now.addingTimeInterval(0.2), now: now) == "[  —  ]")

        // The case `since: Date()`: measured, but below the resolution.
        #expect(Diagnostics.elapsed(since: now, now: now) == "[ <0.1s]")

        // Real spans stay untouched.
        #expect(Diagnostics.elapsed(since: now.addingTimeInterval(-0.6), now: now) == "[  0.6s]")
        #expect(Diagnostics.elapsed(since: now.addingTimeInterval(-12.34), now: now) == "[ 12.3s]")
    }
}

/// A provider's credentials are in the **path**, not in the query.
///
/// The second half of the rule from ``DiagnosticsRedactionTests``, and the one
/// that was missing: in a submitted report the complete stream address of a
/// provider stood twice in plain text, once as `NSErrorFailingURLStringKey`, once
/// as `NSErrorFailingURLKey`. It did not reach the log through a `URL` but as
/// passed-through foreign text.
///
/// **All addresses here are invented.** A real credential in a test is the same
/// mistake as one in the log, only more durable.
@Suite("Credentials in the path of an address")
struct DiagnosticsPathRedactionTests {

    @Test("User and password drop out of the path of a stream address")
    func streamPathCredentialsAreDropped() throws {
        // The shape `XtreamEndpoint.streamURL` produces: no query, the credentials
        // between section and ID.
        let url = try #require(
            URL(string: "http://panel.example:80/live/benutzer/Z2VoZWltZXNQYXNzd29ydA==/340873")
        )

        let logged = Diagnostics.loggable(url)

        #expect(!logged.contains("Z2VoZWltZXNQYXNzd29ydA"))
        #expect(!logged.contains("benutzer"))
        // The ID stays: without it it could no longer be said which channel failed.
        #expect(logged == "http://panel.example:80/live/USER/PASSWORD/340873")
    }

    @Test("Movie and series carry the same credentials in the same place")
    func movieAndSeriesPathsAreMaskedToo() throws {
        let movie = try #require(URL(string: "http://panel.example:80/movie/benutzer/geheim/9911.ts"))
        let series = try #require(URL(string: "http://panel.example:80/series/benutzer/geheim/4711.mkv"))

        #expect(Diagnostics.loggable(movie) == "http://panel.example:80/movie/USER/PASSWORD/9911.ts")
        #expect(
            Diagnostics.loggable(series) == "http://panel.example:80/series/USER/PASSWORD/4711.mkv")
    }

    @Test("A password with a slash is still caught")
    func aSlashInThePasswordDoesNotLeakTheRest() throws {
        // Base64 knows the slash, and `XtreamEndpoint` deliberately does not encode it;
        // otherwise the server would not find the path. A mask on fixed positions would
        // leave the rest of the password standing.
        let url = try #require(URL(string: "http://panel.example:80/live/benutzer/ab/cd/ef/340873"))

        let logged = Diagnostics.loggable(url)

        #expect(logged == "http://panel.example:80/live/USER/PASSWORD/340873")
    }

    @Test("The address of the own media server stays complete")
    func theMediaServerAddressSurvives() throws {
        // The counter test for the lowercase spelling: the media server uses
        // `/LiveTv/…`, and that is no provider address. If the rule applied here, the
        // log would lose its most useful information.
        let url = try #require(URL(string: "http://media.example:8096/LiveTv/Programs"))

        #expect(Diagnostics.loggable(url) == "http://media.example:8096/LiveTv/Programs")
    }

    @Test("Foreign text with an address in it does not go out at all")
    func borrowedTextWithAnAddressIsWithheld() throws {
        // An `NSError` dump, as `localizedDescription` and `String(describing:)`
        // deliver it.
        let dump =
            "Error Domain=NSURLErrorDomain Code=-1005 \"The network connection was lost.\" "
            + "UserInfo={NSErrorFailingURLStringKey=http://panel.example/live/benutzer/geheim/1}"

        let text = try #require(Diagnostics.withoutAddress(dump))

        #expect(!text.contains("://"))
        #expect(!text.contains("geheim"))
        // And the counter test: what carries no address stays word for word.
        #expect(Diagnostics.withoutAddress("HTTP 404: File Not Found") == "HTTP 404: File Not Found")
    }

    /// An error whose description itself carries an address: the side entrance
    /// through which the credentials reached `Diagnostics.failure`.
    private struct Disturbance: Error, CustomStringConvertible {
        let description = "Abbruch bei http://panel.example/live/benutzer/geheim/1"
    }

    @Test("Even the fallback of explain gives out no address")
    func explainFallsBackWithoutAnAddress() {
        #expect(!Diagnostics.explain(Disturbance()).contains("://"))
        #expect(!Diagnostics.explain(Disturbance()).contains("geheim"))

        // The counter test: a known network error is still translated and names its
        // code; otherwise the line would be silent after the change.
        #expect(Diagnostics.explain(URLError(.networkConnectionLost)).contains("-1005"))
    }
}
