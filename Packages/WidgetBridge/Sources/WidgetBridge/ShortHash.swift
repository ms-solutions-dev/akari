import Foundation

/// A short hash for file names — FNV-1a over 64 bits, by hand, because the
/// package should not pull in CryptoKit (the widget pulls in the package). It is about a
/// stable, file-name-safe name per id, not about security; collisions
/// among four titles are not an issue.
enum ShortHash {

    static func hex(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }
}
