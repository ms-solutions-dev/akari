import Foundation
import Testing

@testable import DesignSystem

@Suite("Language choice")
struct LanguageChoiceTests {

    private func persistence() -> (UserDefaults, String) {
        let name = "probe.\(UUID().uuidString)"
        let persistence = UserDefaults(suiteName: name)!
        persistence.removePersistentDomain(forName: name)
        return (persistence, name)
    }

    @Test("A choice writes both keys, system removes both")
    func choiceAndSystem() {
        let (a, name) = persistence()
        LanguageChoice.set("tr", in: a, system: a)
        #expect(LanguageChoice.chosen(a) == "tr")
        #expect(a.stringArray(forKey: LanguageChoice.systemKey) == ["tr"])

        LanguageChoice.set("", in: a, system: a)
        #expect(LanguageChoice.chosen(a) == "")
        // Look in the OWN domain: `object(forKey:)` falls back to the global
        // one, and there the system itself keeps an `AppleLanguages` list.
        #expect(a.persistentDomain(forName: name)?[LanguageChoice.systemKey] == nil)
    }

    @Test("One choice per profile, one system: the switch writes the profile's choice to AppleLanguages")
    func profileSwitch() {
        let (alex, _) = persistence()
        let (kim, _) = persistence()
        let (system, systemName) = persistence()
        LanguageChoice.set("de", in: alex, system: system)
        LanguageChoice.set("tr", in: kim, system: system)
        #expect(LanguageChoice.chosen(alex) == "de")
        #expect(system.stringArray(forKey: LanguageChoice.systemKey) == ["tr"])
        LanguageChoice.adopt(from: alex, in: system)
        #expect(system.stringArray(forKey: LanguageChoice.systemKey) == ["de"])
        let (without, _) = persistence()
        LanguageChoice.adopt(from: without, in: system)
        #expect(system.persistentDomain(forName: systemName)?[LanguageChoice.systemKey] == nil)
    }

    @Test("Every language names itself")
    func names() {
        let names = Dictionary(uniqueKeysWithValues: LanguageChoice.offered.map { ($0.identifier, $0.name) })
        #expect(names["de"] == "Deutsch")
        #expect(names["en"] == "English")
        #expect(names["tr"] == "Türkçe")
    }

    @Test("Without a choice no restart is needed")
    func noRestartWithoutChoice() {
        #expect(!LanguageChoice.needsRestart(persistence().0))
    }
}
