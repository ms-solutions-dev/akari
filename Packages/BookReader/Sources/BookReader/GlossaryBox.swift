import Foundation
import ReadiumShared
import Synchronization

/// Holds the glossary for rebuilding chapters on load: Readium's container passes
/// every resource through here, and a chapter with text gets its terms as
/// `<span class="ss-glossar">` (``Glossary/mark(html:glossary:marked:hint:)``) before the
/// web view sees it. As long as no glossary is set - while searching for it, while counting
/// characters - everything passes through unchanged; it is set before the navigator.
public final class GlossaryBox: Sendable {
    private struct Phase {
        var glossary: Glossary?
        var to = true
        /// Opacity of the line per reading theme (``ReadingStyle/ReadingTheme/line``).
        var hairline = 32
        var pronounced = false
        /// Accent color of the profile for "Prominent" and the fill on tap.
        var accent: UInt32?
        /// Chapter href -> marked mentions (``MarkingPlan``); empty while it computes.
        var plan: [String: Set<Int>] = [:]
        var planReady = false
    }

    private let phase = Mutex(Phase())
    /// VoiceOver hint of every mention (``Glossary/mark(html:glossary:marked:hint:)``).
    private let hint: String

    public init(hint: String = "") {
        self.hint = hint
    }

    public func set(_ glossary: Glossary?, to: Bool) {
        phase.withLock {
            $0.glossary = glossary
            $0.to = to
        }
    }

    /// The book's marking plan - chapters loaded from now on are marked accordingly.
    public func setPlan(_ plan: [String: Set<Int>]) {
        phase.withLock {
            $0.plan = plan
            $0.planReady = true
        }
    }

    public var hairline: Int {
        get { phase.withLock { $0.hairline } }
        set { phase.withLock { $0.hairline = newValue } }
    }

    public var pronounced: Bool {
        get { phase.withLock { $0.pronounced } }
        set { phase.withLock { $0.pronounced = newValue } }
    }

    public var accent: UInt32? {
        get { phase.withLock { $0.accent } }
        set { phase.withLock { $0.accent = newValue } }
    }

    public var to: Bool {
        get { phase.withLock { $0.to } }
        set { phase.withLock { $0.to = newValue } }
    }

    func transform(_ href: AnyURL, _ resource: Resource) -> Resource {
        let z = phase.withLock { $0 }
        guard let glossary = z.glossary, GlossaryBox.isChapter(href.string),
            !glossary.chapter.contains(where: { SpineCard.equal($0, href.string) })
        else { return resource }
        // With a plan: exactly its mentions (a chapter without an entry has no line);
        // without a plan (still computing): the first mention of each term in the chapter.
        let marked: Set<Int>? =
            z.planReady ? (z.plan.first { SpineCard.equal($0.key, href.string) }?.value ?? []) : nil
        let hint = hint
        return resource.mapAsString {
            Glossary.mark(
                html: $0, glossary: glossary, to: z.to, marked: marked, hint: hint,
                hairline: z.hairline, pronounced: z.pronounced, accent: z.accent)
        }
    }

    static func isChapter(_ href: String) -> Bool {
        let path = href.split(separator: "?").first.map(String.init) ?? href
        let fileExtension = (path.split(separator: "#").first.map(String.init) ?? path).lowercased()
        return fileExtension.hasSuffix(".xhtml") || fileExtension.hasSuffix(".html")
            || fileExtension.hasSuffix(".htm")
            || fileExtension.hasSuffix(".xml")
    }
}
