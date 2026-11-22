import Foundation

/// German, English, Turkish - or as the system.
///
/// Each language names itself ("Deutsch", "English", "Türkçe"), not in the
/// language currently set: whoever set the app to Turkish and wants to go back would
/// otherwise search for "Almanca".
///
/// **The route via `AppleLanguages`** (taken from CineLounge for the phone): iOS reads
/// the key at start and then translates the whole catalog - tabs,
/// system buttons, date formats. An `.environment(\.locale)` at the root did not reach
/// the system parts. The price is a restart after the change, and that is
/// stated, not hidden.
///
/// **Per profile, but one system**: the choice lives in the profile's
/// UserDefaults; iOS only reads `AppleLanguages` from the standard UserDefaults, so
/// on a profile switch the new profile's choice is written there
/// - and the restart hint then applies as after a choice in the sheet.
public enum LanguageChoice {

    /// Where the choice lives - a storage key, not a language key.
    public static let storeKey = "app.language"

    static let systemKey = "AppleLanguages"

    /// What is offered. Empty means "as the system".
    public static let offered: [(identifier: String, name: String)] = [
        ("", "System"), ("de", "Deutsch"), ("en", "English"), ("tr", "Türkçe"),
    ]

    public static func chosen(_ persistence: UserDefaults = .standard) -> String {
        persistence.string(forKey: storeKey) ?? ""
    }

    /// - Parameters:
    ///   - persistence: the profile's UserDefaults - the choice lives there
    ///   - system: the standard UserDefaults - where iOS reads `AppleLanguages`
    public static func set(
        _ identifier: String, in persistence: UserDefaults = .standard, system: UserDefaults = .standard
    ) {
        if identifier.isEmpty {
            persistence.removeObject(forKey: storeKey)
        } else {
            persistence.set(identifier, forKey: storeKey)
        }
        adopt(from: persistence, in: system)
    }

    /// Writes a profile's choice into the system UserDefaults - on switching.
    public static func adopt(from persistence: UserDefaults, in system: UserDefaults = .standard) {
        let identifier = chosen(persistence)
        if identifier.isEmpty {
            // Remove it rather than set "de": without an entry iOS uses the
            // order of the system languages again - exactly what "as the system" means.
            system.removeObject(forKey: systemKey)
        } else {
            system.set([identifier], forKey: systemKey)
        }
    }

    /// The language the app is currently running in.
    public static func inProgress() -> String {
        Bundle.main.preferredLocalizations.first ?? ""
    }

    /// Whether the choice only applies after a restart.
    public static func needsRestart(_ persistence: UserDefaults = .standard) -> Bool {
        let choice = chosen(persistence)
        guard !choice.isEmpty else { return false }
        return !inProgress().hasPrefix(choice)
    }
}
