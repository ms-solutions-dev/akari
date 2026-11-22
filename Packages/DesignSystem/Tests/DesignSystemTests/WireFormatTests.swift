import Foundation
import Testing

@testable import DesignSystem

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func rawValues() {
        #expect(Set(Appearance.allCases.map(\.rawValue)) == ["dunkel", "hell", "system"])
        #expect(Set(ColorTheme.allCases.map(\.rawValue)) == ["indigo", "pflaume", "terrakotta", "tinte"])
        #expect(Set(Worm.Pose.allCases.map(\.rawValue)) == ["jubel", "lesen", "suchen", "willkommen"])
    }
}
