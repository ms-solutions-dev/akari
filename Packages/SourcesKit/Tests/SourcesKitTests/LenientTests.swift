import Foundation
import Testing

@testable import SourcesKit

@Suite("Lenient")
struct LenientTests {

    struct Book: Decodable, Sendable, Equatable {
        let id: Int
        let title: String

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case title = "titel"
        }
    }

    struct Answer: Decodable {
        @Lenient var books: [Book]

        enum CodingKeys: String, CodingKey {
            case books = "buecher"
        }
    }

    @Test("A broken entry goes missing alone, the others stay — also numbers, texts and null")
    func skips() throws {
        let json =
            #"{"buecher": [{"id": 1, "titel": "A"}, {"id": 2}, 7, "x", null, [1], {"id": 3, "titel": "C"}]}"#
        let response = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        #expect(response.books == [Book(id: 1, title: "A"), Book(id: 3, title: "C")])
        #expect(response.$books.discarded == 5)
    }

    @Test("If the list is missing, it is empty")
    func missing() throws {
        let response = try JSONDecoder().decode(Answer.self, from: Data("{}".utf8))
        #expect(response.books.isEmpty)
    }

    @Test("Also at top level")
    func topLevel() throws {
        let list = try JSONDecoder().decode(
            Lenient<Book>.self, from: Data(#"[{"id":1,"titel":"A"},{}]"#.utf8))
        #expect(list.wrappedValue.count == 1)
        #expect(list.discarded == 1)
    }
}
