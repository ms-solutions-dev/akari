import Foundation
import SourcesKit

/// The reading state as the OPDS 2.0 progression API carries it
/// (`http://www.cantook.com/api/progression`, `application/vnd.readium.progression+json`):
/// when, from which device, and a Readium locator with the position.
///
/// Komga (`CommonBookController`, `R2Progression`) reads and writes exactly this shape at
/// `/opds/v2/books/{id}/progression`: `GET` returns 204 without a state, `PUT` answers 204, 409
/// if `modified` is not after the stored state, 400 if the position does not fit. For comics
/// (Divina) `locations.position` counts, 1-based up to the page count; there is no `completed`
/// field — Komga sets it when the position is the last page, and the app reads it the same way.
///
/// **What comes back can be empty:** A state written by the Komga web reader is returned by the
/// server with a locator without `locations` (`href` and `type` empty) — the page only knows the
/// REST interface. The app then knows that a state exists, but not where; ``readingState(pages:)``
/// returns `nil`.
struct OpdsProgression: Codable, Sendable, Hashable {
    var modified: Date
    var device: DeviceInfo
    var locator: Locator

    struct DeviceInfo: Codable, Sendable, Hashable {
        var id: String
        var name: String
    }

    struct Locator: Codable, Sendable, Hashable {
        var href: String
        var type: String
        var title: String?
        var locations: Locations?
    }

    struct Locations: Codable, Sendable, Hashable {
        var fragments: [String]?
        var progression: Double?
        var position: Int?
        var totalProgression: Double?
    }

    /// From a page state: the page as `position`, the fraction as `totalProgression`, the device
    /// name from the state (the reader writes it in) — the device identifier is the name in
    /// lowercase without spaces, so that Komga recognizes the same device.
    ///
    /// - Parameters:
    ///   - page: address and type of the page from the manifest if it was already there; otherwise
    ///     the address of the manifest — Komga does not check the `href` for comics.
    init?(_ state: ReadingState, page: (href: String, type: String?)) {
        guard case .page(let number, let from) = state.position else { return nil }
        let name = state.device ?? "Akari"
        modified = state.timestamp
        device = DeviceInfo(
            id: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name)
        locator = Locator(
            href: page.href, type: page.type ?? "image/jpeg",
            title: String(
                format: String(localized: "opds.progression.page", defaultValue: "Page %lld", bundle: .main),
                number),
            locations: Locations(
                fragments: nil, progression: nil, position: number,
                totalProgression: from > 0 ? min(max(Double(number) / Double(from), 0), 1) : nil))
    }

    /// Back into a ``ReadingState``: the page from `position`, otherwise computed from
    /// `totalProgression`; completed when the last page is reached. `nil` if the locator names no
    /// position.
    func readingState(pages: Int) -> ReadingState? {
        guard let spots = locator.locations else { return nil }
        let page: Int
        if let position = spots.position {
            page = position
        } else if let fraction = spots.totalProgression, pages > 0 {
            page = max(1, Int((fraction * Double(pages)).rounded()))
        } else {
            return nil
        }
        let from = max(pages, page)
        return ReadingState(
            position: .page(page, from: from), timestamp: modified,
            device: device.name.isEmpty ? nil : device.name,
            completed: pages > 0 && page >= pages)
    }

    /// The body for `PUT`: ISO-8601 with fractions (Komga compares `modified` to the millisecond
    /// with the stored state), keys sorted.
    func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso.string(from: date))
        }
        return try encoder.encode(self)
    }

    /// Reads the response to `GET` — the date with or without fractions, with `Z` or a time zone
    /// (Komga writes nanoseconds and `+02:00`).
    static func parse(_ data: Data) throws -> OpdsProgression {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = OpdsParser.date(text) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return try decoder.decode(OpdsProgression.self, from: data)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
