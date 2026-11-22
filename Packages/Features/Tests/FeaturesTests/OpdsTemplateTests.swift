import Testing

@testable import Features

@Suite("OPDS templates")
struct OpdsTemplateTests {

    @Test("A bare server address gets the template's catalog path")
    func pathAttached() {
        #expect(
            OpdsTemplate.catalogAddress("buecher.example.com", template: .calibreWeb)
                == "buecher.example.com/opds")
        #expect(
            OpdsTemplate.catalogAddress(" https://x.example:8083/ ", template: .calibre)
                == "https://x.example:8083/opds")
        #expect(
            OpdsTemplate.catalogAddress("stump.example", template: .stump)
                == "stump.example/opds/v1.2/catalog"
        )
    }

    @Test("Whoever types a path is not overruled")
    func pathStays() {
        #expect(
            OpdsTemplate.catalogAddress("x.example/mein/katalog", template: .stump)
                == "x.example/mein/katalog"
        )
        #expect(
            OpdsTemplate.catalogAddress("https://x.example/opds/", template: .calibreWeb)
                == "https://x.example/opds")
    }

    @Test("\"Other\" and empty input change nothing")
    func nothing() {
        #expect(OpdsTemplate.catalogAddress("x.example", template: .other) == "x.example")
        #expect(OpdsTemplate.catalogAddress("  ", template: .calibreWeb) == "")
    }
}
