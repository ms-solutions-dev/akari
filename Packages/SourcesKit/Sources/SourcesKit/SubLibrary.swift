import Foundation

/// A library within a server — Grimmory "Books" and "Reference", Komga
/// "Manga" and "Comics". Someone with tens of thousands of titles in several of them may want
/// only some in the app (library tier 2).
public struct SubLibrary: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which sub-libraries of an account the app hides — remembered per account and device.
/// The switched-off ones are stored, so that a new library on the server shows up on its own.
public enum LibraryPicker {

    static func lookupKey(_ identifier: SourceID) -> String { "bibliotheken.aus." + identifier.description }

    public static func from(_ identifier: SourceID, _ persistence: UserDefaults = .standard) -> Set<String> {
        Set(persistence.stringArray(forKey: lookupKey(identifier)) ?? [])
    }

    public static func set(
        from: Set<String>, for identifier: SourceID, _ persistence: UserDefaults = .standard
    ) {
        if from.isEmpty {
            persistence.removeObject(forKey: lookupKey(identifier))
        } else {
            persistence.set(from.sorted(), forKey: lookupKey(identifier))
        }
    }

    /// From how many titles the app asks after sign-in which libraries to show —
    /// below that it simply loads all of them.
    public static let ask = 5_000
}
