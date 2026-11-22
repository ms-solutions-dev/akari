import Foundation

/// A list from a server response that skips individual unreadable entries instead of
/// failing as a whole.
///
/// **Why:** a single book without a title or with a broken date made the whole catalog of a
/// source ``SourceError/unreadable(_:_:)`` — with Grimmory at 35,000 books, with Komga per
/// page, with Audiobookshelf per library. The source then went missing silently. Now only
/// that one book is missing; ``discarded`` says how many there were.
///
/// As a property wrapper, so that the response types keep their synthesized `Decodable`:
/// `@Lenient var results: [Entry]`.
@propertyWrapper
public struct Lenient<Element: Decodable & Sendable>: Decodable, Sendable {

    public var wrappedValue: [Element]
    /// How many entries were unreadable.
    public var discarded: Int

    /// `$list.discarded` — for diagnostics.
    public var projectedValue: Lenient<Element> { self }

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
        self.discarded = 0
    }

    public init(from decoder: any Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var values: [Element] = []
        var discarded = 0
        if let count = list.count { values.reserveCapacity(count) }
        while !list.isAtEnd {
            if let value = try? list.decode(Element.self) {
                values.append(value)
            } else {
                // Move on: a failed entry does not advance the cursor.
                _ = try list.decode(Skip.self)
                discarded += 1
            }
        }
        self.wrappedValue = values
        self.discarded = discarded
    }

    /// Accepts any JSON value and forgets it.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    /// If the key is missing, the list is empty — like an optional field.
    public func decode<Element>(
        _ type: Lenient<Element>.Type, forKey key: Key
    ) throws
        -> Lenient<Element>
    {
        try decodeIfPresent(type, forKey: key) ?? Lenient(wrappedValue: [])
    }
}
