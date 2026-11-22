import Foundation

/// The licenses of third-party packages, **read and not maintained.**
///
/// **Why at all:** Apple does not require third-party licenses, **the licenses
/// themselves do.** Apache 2.0 section 4 and the MIT license both want notice
/// and license text to be shipped along.
///
/// **A list maintained by hand drifts apart on the first day somebody swaps a
/// package**, and unnoticed, because a wrong license list looks like a right
/// one. So a tool reads what really travels along: `Package.resolved` names the
/// resolved packages with their version, and the checkouts of the source
/// packages hold their license files.
public enum Licenses {

    public struct Package: Sendable, Decodable {
        public let name: String
        public let edition: String
        /// The source location. It is in the file and is not shown on the television:
        /// an address nobody can click is a line without purpose.
        public let place: String
        /// `nil` if no license file was found for this package.
        public let kind: String?
        public let text: String?
        /// Which version of the checkout the text comes from, if the resolved state
        /// itself carries no license file.
        public let filledIn: String?

        /// What is on the right of the row.
        ///
        /// **A gap is named and not concealed:** a package without a license file at its
        /// source location is not a package without a license; it is one whose license
        /// somebody must add.
        public var kindOrGap: String { kind ?? "—" }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case edition = "fassung"
            case place = "ort"
            case kind = "art"
            case text
            case filledIn = "nachgetragen"
        }
    }

    /// All packages, read once.
    ///
    /// **Empty if the file is missing,** and the view says so. An empty area without
    /// explanation would look like a drawing error.
    public static let all: [Package] = {
        guard let place = Bundle.main.url(forResource: "Lizenzen", withExtension: "json"),
            let data = try? Data(contentsOf: place),
            let read = try? JSONDecoder().decode([Package].self, from: data)
        else { return [] }
        return read
    }()
}
