import Foundation
import Testing

@testable import Bedrock

/// The crash guard, tested without a crash: the handler writes on command, and
/// the next "launch" reads what it left behind.
@Suite("The crash guard", .serialized)
struct CrashGuardTests {

    private func freshFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "absturz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A proper run leaves nothing")
    func cleanRunLeavesNothing() throws {
        let folder = try freshFolder()
        CrashGuard.install(directory: folder, catching: false)
        #expect(CrashGuard.takePreviousReport() == nil)
        // A second launch without a crash in between: still nothing.
        CrashGuard.install(directory: folder, catching: false)
        #expect(CrashGuard.takePreviousReport() == nil)
    }

    @Test("What the handler writes, the next launch reads")
    func writtenReportIsReadOnNextLaunch() throws {
        let folder = try freshFolder()
        CrashGuard.install(directory: folder, catching: false)
        CrashGuard.note(activity: "Wiedergabe „DE: Sender 2 UHD“ — Motor renderer")
        CrashGuard.write(signal: SIGSEGV)

        CrashGuard.install(directory: folder, catching: false)
        let report = try #require(CrashGuard.takePreviousReport())
        #expect(report.contains("Signal 11"))
        #expect(report.contains("during: Wiedergabe „DE: Sender 2 UHD“"))
        #expect(report.contains("image loaded at 0x"))
        // The call chain: at least one frame with an address.
        #expect(report.contains("0x"))

        let (header, kette) = CrashGuard.lines(from: report)
        #expect(header.contains("Signal 11"))
        #expect(header.contains("during:"))
        #expect(!header.contains("Version:"), "the head does not repeat the diagnosis")
        #expect(!kette.isEmpty)
        #expect(!kette.contains("  "), "the chain is boiled down")

        // Collected is collected.
        #expect(CrashGuard.takePreviousReport() == nil)
        // And the new run starts with an empty file.
        CrashGuard.install(directory: folder, catching: false)
        #expect(CrashGuard.takePreviousReport() == nil)
    }

    @Test("The chain is reduced to what is readable")
    func framesAreLimited() {
        var text = "Signal 6 (SIGABRT)\nduring: Probe\n"
        for i in 0..<50 { text += "\(i)   CineLounge    0x00000001000\(i)   CineLounge + \(i)\n" }
        let (_, kette) = CrashGuard.lines(from: text, frameLimit: 5)
        #expect(kette.split(separator: "|").count == 5)
    }
}

/// The memory watch: the footprint must be a number, not a zero.
@Suite("The memory watch")
struct MemoryWatchTests {
    @Test("The footprint is measurable")
    func footprintIsMeasurable() {
        #expect(MemoryWatch.footprintBytes > 1_000_000)
        #expect(MemoryWatch.footprintText.hasSuffix(" MB"))
    }
}
