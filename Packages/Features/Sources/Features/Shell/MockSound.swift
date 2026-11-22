import Foundation
import SourcesKit

/// A transport that delays every track of an audiobook by a few milliseconds, only for
/// `AKARI_PROBE=hoerbuch-behalten`: the mock answers from memory, and 600 tracks are on
/// disk in under a second, so the ring would never show in a screenshot. With 50 ms per
/// track keeping takes half a minute, like a small audiobook through the tunnel.
struct ThrottledTransport: Transport {

    let inner: any Transport
    let delay: Duration

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path().contains("/file/") == true { try await Task.sleep(for: delay) }
        return try await inner.send(request)
    }
}

/// One minute of sound for the preview with mocks: three chapters, three pitches, as WAV
/// (PCM, 8 kHz, mono), 960 KB, which AVPlayer plays without detours.
enum MockSound {

    static func wav() -> Data {
        let rate = 8_000
        let seconds = 60
        let count = rate * seconds
        var samples = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            // One tone per chapter, half a second of silence between; the change is audible.
            let chapter = Int(t / 20)
            let inChapter = t - Double(chapter) * 20
            let frequency = [220.0, 330.0, 440.0][chapter % 3]
            let shell = inChapter < 0.5 ? 0.0 : 0.25
            let value = Int16(sin(2 * .pi * frequency * t) * shell * Double(Int16.max))
            samples.append(UInt8(truncatingIfNeeded: value))
            samples.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        var header = Data()
        func integer(_ w: UInt32) {
            for s in stride(from: 0, to: 32, by: 8) { header.append(UInt8((w >> s) & 0xFF)) }
        }
        func integer(_ w: UInt16) { header.append(UInt8(w & 0xFF)); header.append(UInt8(w >> 8)) }
        header.append(contentsOf: Array("RIFF".utf8))
        integer(UInt32(36 + samples.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(rate))
        integer(UInt32(rate * 2))
        integer(UInt16(2))
        integer(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        integer(UInt32(samples.count))
        return header + samples
    }
}
