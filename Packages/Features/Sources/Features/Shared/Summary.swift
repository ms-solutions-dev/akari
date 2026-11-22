import Bedrock
import DesignSystem
import NaturalLanguage
import SwiftUI

#if canImport(Translation)
    import Translation
#endif

/// The summary of a title or series, collapsed to five lines with "More", because Komga's
/// texts come with publisher notes, Markdown and link lists and would otherwise bury the
/// volumes below.
///
/// Markdown is not rendered but stripped: `**bold**` loses the asterisks, `[Name](https://...)`
/// becomes "Name", bare addresses are dropped. What remains is the text; whoever wants the
/// links has the web interface.
///
/// **Translating on the device:** if the text is in a different language than the device
/// (for example Polish or English on a German device), a button appears below. Apple's
/// translation runs without a service and without an account; the system fetches the
/// language packs the first time. On an English device, English texts show no button.
struct Summary: View {
    /// "Reduce motion": then without animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    @State private var unresolved = false
    @State private var translation: String?
    @State private var original = false
    /// Only after the user's own tap on "Translate": if the automatic job fails, the button
    /// silently stays.
    @State private var failure = false
    /// What Apple says when it does not work; "Translation not possible" alone helped nobody.
    @State private var errorText: String?
    /// Whether the running job comes from the tap (then it may show an error).
    @State private var tapped = false
    /// The automatic job tried once; not at every appearance again.
    @State private var automaticTried = false
    #if canImport(Translation)
        @State private var job: TranslationSession.Configuration?
    #endif
    /// Translate foreign-language texts right away (setting); "Original" stays one tap away.
    /// On by default: for readers in German-speaking countries an English blurb with
    /// "Translate" below was the normal case. Whoever switched it off keeps that, since the
    /// value is already stored.
    @AppStorage(Summary.automaticKey) private var automatic = true

    /// Storage key (UserDefaults): stays `text.automatisch`, although the catalog key is `text.automatic`.
    static let automaticKey = "text.automatisch"

    var body: some View {
        let cleaned = Summary.cleaned(text)
        if !cleaned.isEmpty {
            let foreign = Summary.foreignLanguage(cleaned)
            let shown = (original ? nil : translation) ?? cleaned
            VStack(alignment: .leading, spacing: 6) {
                // Reading text in the serif: in the grotesque of the secondary lines the
                // screen's largest paragraph looked like settings text.
                Text(verbatim: shown)
                    .font(Typography.title(.subheadline, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(ColorTheme.typography.color)
                    .lineLimit(unresolved ? nil : 5)
                HStack(spacing: 16) {
                    if shown.count > 240 {
                        Button {
                            withAnimation(Motion.soft(reduceMotion)) { unresolved.toggle() }
                        } label: {
                            Text(app: unresolved ? "text.fewer" : "text.more")
                        }
                    }
                    if let foreign {
                        translationButton(foreign, cleaned)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            .readingWidth()
            #if canImport(Translation)
                .task(id: automatic) {
                    guard automatic, let foreign, translation == nil, job == nil, !failure,
                        !automaticTried
                    else { return }
                    automaticTried = true
                    tapped = false
                    job = TranslationSession.Configuration(
                        source: Locale.Language(identifier: foreign), target: Locale.current.language)
                }
                .translationTask(job) { session in
                    // `TranslationSession` is not `Sendable`, but `translate` runs off the
                    // main thread; the session belongs to this one call and nobody else
                    // touches it, so this is safe.
                    nonisolated(unsafe) let session = session
                    switch await Summary.translate(session, cleaned) {
                    case .success(let result):
                        translation = result
                        original = false
                    case .failure(let reason):
                        if tapped {
                            failure = true
                            errorText = reason.localizedDescription
                        }
                        Diagnostics.network.error(
                            "Translation failed: \(String(describing: reason), privacy: .public)")
                    }
                    job = nil
                }
            #endif
        }
    }

    @ViewBuilder
    private func translationButton(_ foreign: String, _ cleaned: String) -> some View {
        if translation != nil {
            Button {
                original.toggle()
            } label: {
                Text(app: original ? "text.translation" : "text.original")
            }
            if !original {
                Text(verbatim: Phrase.from("text.translated", Summary.languageName(foreign)))
                    .font(.caption)
                    .foregroundStyle(ColorTheme.muted.color)
            }
        } else if failure {
            // One sentence: Apple's reason if there is one, otherwise ours.
            Text(verbatim: errorText ?? Phrase.from("text.translation.missing"))
                .font(.caption)
                .foregroundStyle(ColorTheme.muted.color)
        } else {
            #if canImport(Translation)
                Button {
                    tapped = true
                    job = TranslationSession.Configuration(
                        source: Locale.Language(identifier: foreign), target: Locale.current.language)
                } label: {
                    Text(verbatim: Phrase.from("text.translate", Summary.languageName(foreign)))
                }
            #endif
        }
    }

    #if canImport(Translation)
        /// Request the language pack first (that shows the user Apple's download sheet if it
        /// is missing), then translate.
        nonisolated static func translate(
            _ session: TranslationSession, _ text: String
        ) async
            -> Result<String, Error>
        {
            do {
                try await session.prepareTranslation()
                return .success(try await session.translate(text).targetText)
            } catch {
                return .failure(error)
            }
        }
    #endif

    /// The text's language as a code if it is recognized with confidence and is not the
    /// device's; otherwise `nil` and there is no button.
    static func foreignLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(600)))
        guard let language = recognizer.dominantLanguage,
            let confidence = recognizer.languageHypotheses(withMaximum: 1)[language], confidence > 0.6
        else { return nil }
        let device = Locale.current.language.languageCode?.identifier ?? "de"
        let recognized =
            Locale.Language(identifier: language.rawValue).languageCode?.identifier ?? language.rawValue
        return recognized == device ? nil : language.rawValue
    }

    /// "Polish", in the device's language.
    static func languageName(_ abbreviation: String) -> String {
        Locale.current.localizedString(forLanguageCode: abbreviation)?.capitalized(with: .current)
            ?? abbreviation
    }

    /// Markdown and link lists out, paragraphs collapsed to one blank line.
    static func cleaned(_ text: String) -> String {
        var t = Summary.withoutHTML(text)
        // [Name](address) -> Name
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // bare addresses removed
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " .", with: ".")
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        // Lines that carry only punctuation after stripping are link lists
        let rows = t.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        .filter { line in line.isEmpty || line.contains { $0.isLetter || $0.isNumber } }
        t = rows.joined(separator: "\n")
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Grimmory's blurbs from Amazon arrive as HTML (`<p><b>"A harrowing ..." Newspaper</b></p><br>`):
    /// paragraphs and breaks become lines, all other tags are dropped, the common entities
    /// become characters. No parser; a blurb is not a document.
    static func withoutHTML(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var t = text
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"(?i)</(p|div|h[1-6]|li|tr)>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&apos;", "'"), ("&raquo;", "»"), ("&laquo;", "«"), ("&bdquo;", "„"), ("&ldquo;", "“"),
            ("&rdquo;", "”"), ("&hellip;", "…"), ("&ndash;", "–"), ("&mdash;", "—"),
        ] {
            t = t.replacingOccurrences(of: entity, with: character)
        }
        t = t.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        return t
    }
}
