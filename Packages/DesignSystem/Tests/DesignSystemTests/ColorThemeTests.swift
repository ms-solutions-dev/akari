import CloudSync
import Foundation
import Testing

@testable import DesignSystem

/// The contrasts from the design reference, recomputed: accent on paper
/// >= 4.5 : 1, ink on paper >= 7 : 1, button text on accent >= 4.5 : 1 - in all
/// four themes, light and dark. Whoever changes a value fails here, not on the
/// device.
@Suite("Theme")
struct ThemaTests {

    @Test("WCAG computation holds for known pairs")
    func computation() {
        #expect(abs(AdaptiveColor.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(AdaptiveColor.contrast(0xFFFFFF, 0xFFFFFF) - 1) < 0.01)
        // Terracotta light is the tightest pair per the reference: 5.4 : 1.
        #expect(abs(AdaptiveColor.contrast(0xA9482B, 0xFBF7F2) - 5.4) < 0.15)
    }

    @Test("Accent on paper ≥ 4.5 : 1 in all eight cases", arguments: ColorTheme.allCases)
    func accent(theme: ColorTheme) {
        #expect(AdaptiveColor.contrast(theme.accent.light, theme.paper.light) >= 4.5, "\(theme) hell")
        #expect(AdaptiveColor.contrast(theme.accent.dark, theme.paper.dark) >= 4.5, "\(theme) dunkel")
        // The accent must also be readable on the surface (segment, search field).
        #expect(
            AdaptiveColor.contrast(theme.accent.light, theme.surface.light) >= 4.5, "\(theme) light, surface")
        #expect(
            AdaptiveColor.contrast(theme.accent.dark, theme.surface.dark) >= 4.5, "\(theme) dark, surface")
    }

    @Test("Ink on paper ≥ 7 : 1, secondary ≥ 4.5 : 1", arguments: ColorTheme.allCases)
    func ink(theme: ColorTheme) {
        #expect(AdaptiveColor.contrast(ColorTheme.typography.light, theme.paper.light) >= 7, "\(theme) hell")
        #expect(AdaptiveColor.contrast(ColorTheme.typography.dark, theme.paper.dark) >= 7, "\(theme) dunkel")
        #expect(
            AdaptiveColor.contrast(ColorTheme.muted.light, theme.paper.light) >= 4.5,
            "\(theme) hell, Nebenton")
        #expect(
            AdaptiveColor.contrast(ColorTheme.muted.dark, theme.paper.dark) >= 4.5,
            "\(theme) dunkel, Nebenton")
    }

    @Test("Button text on accent: white in light, paper in dark", arguments: ColorTheme.allCases)
    func button(theme: ColorTheme) {
        #expect(AdaptiveColor.contrast(theme.buttonText.light, theme.accent.light) >= 4.5, "\(theme) hell")
        #expect(AdaptiveColor.contrast(theme.buttonText.dark, theme.accent.dark) >= 4.5, "\(theme) dunkel")
    }

    @Test("Default is ink, every theme has a language key")
    func preset() {
        #expect(ColorTheme.preset == .ink)
        #expect(
            ColorTheme.allCases.map(\.lookupKey) == [
                "theme.tinte", "theme.terrakotta", "theme.indigo", "theme.pflaume",
            ])
    }

    @Test("Theme choice: reads the mirror, writes it, without iCloud")
    @MainActor
    func choice() {
        let name = "probe.\(UUID().uuidString)"
        let persistence = UserDefaults(suiteName: name)!
        persistence.removePersistentDomain(forName: name)
        let choice = ThemeChoice(persistence: persistence, cloud: nil)
        #expect(choice.chosen == .ink)
        choice.set(.plum)
        #expect(persistence.string(forKey: ThemeChoice.storeKey) == "pflaume")
        #expect(ThemeChoice(persistence: persistence, cloud: nil).chosen == .plum)
        persistence.set("unsinn", forKey: ThemeChoice.storeKey)
        #expect(ThemeChoice(persistence: persistence, cloud: nil).chosen == .ink)
    }
}

/// The theme per profile via the zone: two profiles, two zones; the other
/// device reads the state; the transition fetches the old key.
@Suite("Theme choice per profile")
@MainActor
struct ThemeChoiceProfileTests {

    private let server = CloudMock()

    private func persistence() -> UserDefaults {
        let name = "probe.\(UUID().uuidString)"
        let persistence = UserDefaults(suiteName: name)!
        persistence.removePersistentDomain(forName: name)
        return persistence
    }

    private func zone(_ identifier: ZoneID) -> ProfileZone {
        ProfileZone(file: nil, service: server.access("alex"), zone: identifier, unprompted: false)
    }

    @Test("Two profiles, two zones; the other device reads the state")
    func twoProfiles() async {
        let profileZone = ZoneID(profile: UUID())
        let wm = zone(profileZone)
        let ws = zone(ZoneID(profile: UUID()))
        let alex = ThemeChoice(persistence: persistence(), cloud: wm)
        let choiceOnPhone = ThemeChoice(persistence: persistence(), cloud: ws)
        alex.set(.indigo)
        choiceOnPhone.set(.plum)
        await wm.equalSince()
        await ws.equalSince()
        let padZone = zone(profileZone)
        await padZone.equalSince()
        #expect(ThemeChoice(persistence: persistence(), cloud: padZone).chosen == .indigo)
        #expect(ThemeChoice(persistence: persistence(), cloud: zone(ZoneID(profile: UUID()))).chosen == .ink)
        // Changed remotely: the observer applies it.
        ThemeChoice(persistence: persistence(), cloud: padZone).set(.terracotta)
        await padZone.equalSince()
        await wm.equalSince()
        #expect(alex.chosen == .terracotta)
    }

    @Test("The transition fetches the old key and removes it")
    func transition() {
        let old = StorageMock(["profil.alex.theme": "pflaume"])
        let w = zone(ZoneID(profile: UUID()))
        let choice = ThemeChoice(
            persistence: persistence(), cloud: w,
            legacyData: LegacyData(old, lookupKey: ThemeChoice.cloudKey(profile: "alex")))
        #expect(choice.chosen == .plum && old.values.isEmpty)
        #expect(w.record(type: "Profileinstellung", name: "theme")?["wert"]?.text == "pflaume")
    }
}

@Suite("Color")
struct ColorThemeTests {

    @Test("The same color is the same - otherwise SwiftUI redraws every spot on every pass")
    func equal() {
        let color = AdaptiveColor(light: 0x112233, dark: 0x445566)
        #expect(color.color == color.color)
        #expect(AdaptiveColor(light: 0x112233, dark: 0x445566).color == color.color)
        #expect(AdaptiveColor(0x112233).color != color.color)
    }
}
