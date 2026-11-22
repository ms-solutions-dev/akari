import SwiftUI

extension Text {

    /// A translated text from within a package.
    ///
    /// Necessary because `Text("key")` inside a package looks up in the **package bundle**,
    /// not in the app's - and the string catalog lives with the app target
    /// (`App/Resources/Localizable.xcstrings`). Without this the
    /// key name appears untranslated on screen, and nothing fails.
    public init(app lookupKey: LocalizedStringKey) {
        self.init(lookupKey, bundle: .main)
    }

    /// The same for a key that only arises at runtime.
    ///
    /// For example `Text(appKey: "kind." + kind.rawValue)`. The strings checker cannot see such
    /// keys and therefore reports them as orphaned - that is a hint,
    /// not an error.
    public init(appKey lookupKey: String) {
        self.init(LocalizedStringKey(lookupKey), bundle: .main)
    }
}

extension Label where Title == Text, Icon == Image {

    /// Label and glyph, translated from the app bundle.
    public init(app lookupKey: LocalizedStringKey, systemImage name: String) {
        self.init {
            Text(app: lookupKey)
        } icon: {
            Image(systemName: name)
        }
    }

    /// The same for a key that only arises at runtime.
    public init(appKey lookupKey: String, systemImage name: String) {
        self.init {
            Text(appKey: lookupKey)
        } icon: {
            Image(systemName: name)
        }
    }
}
