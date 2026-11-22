import Foundation
import Testing

@testable import Bedrock

/// The disk trace must stay short on its own; nobody maintains a log file on a
/// television. Tested are the two limits and that trimming keeps the youngest:
/// a trace that sacrifices the newest would be worse than none.
@Suite("Disk trace of the diagnostics")
struct TraceRecorderTests {

    private func freshDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spur-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Appended lines come back with a timestamp")
    func roundTrip() async throws {
        let recorder = TraceRecorder(directory: try freshDirectory())
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        await recorder.append("Anmeldung  https://server  ✓", at: noon)
        await recorder.append("Bibliothek  https://server/Items  ✗ Zeitüberschreitung", at: noon)

        let text = await recorder.contents()
        #expect(text.contains("2026-08-07T12:00:00Z\tAnmeldung"))
        #expect(text.contains("✗ Zeitüberschreitung"))
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test("Anything older than three days falls out on the next run")
    func trimsByAge() async throws {
        let directory = try freshDirectory()
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        let first = TraceRecorder(directory: directory)
        await first.append("alt", at: noon.addingTimeInterval(-4 * 24 * 3600))
        await first.append("frisch", at: noon.addingTimeInterval(-3600))

        // A new run: trimming takes effect on the first write, as at app launch.
        let second = TraceRecorder(directory: directory)
        await second.append("neu", at: noon)

        let text = await second.contents()
        #expect(!text.contains("alt"))
        #expect(text.contains("frisch"))
        #expect(text.contains("neu"))
    }

    @Test("Above the size cap it is trimmed at the front, not at the back")
    func trimsBySize() async throws {
        let recorder = TraceRecorder(directory: try freshDirectory())
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        // Lines of about 1000 characters each until the cap has been burst twice;
        // trimming must sacrifice the oldest every time.
        let filler = String(repeating: "x", count: 1000)
        for index in 0..<2300 {
            await recorder.append("Zeile \(index)  \(filler)", at: noon)
        }

        let text = await recorder.contents()
        #expect(text.utf8.count <= TraceRecorder.maxBytes)
        #expect(!text.contains("Zeile 0 "))
        #expect(text.contains("Zeile 2299 "))
    }

    @Test("Line breaks in an entry do not tear the trace apart")
    func flattensNewlines() async throws {
        let recorder = TraceRecorder(directory: try freshDirectory())
        let noon = try Date.ISO8601FormatStyle().parse("2026-08-07T12:00:00Z")

        // Measurements are multi-line: stored as one line, the timestamp stays true per
        // line, and the age trimming never throws away half a measurement.
        await recorder.append("Messung  Zeile eins\nZeile zwei", at: noon)

        let lines = await recorder.contents().split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].contains("Zeile eins Zeile zwei"))
    }
}
