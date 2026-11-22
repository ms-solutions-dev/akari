import Foundation
import SourcesKitMocks
import Testing

@testable import BookReader

@Suite("Book location - CFI")
struct BookLocationTests {

    @Test("A CFI from Grimmory is read and written back")
    func roundTrip() throws {
        let spot = try #require(BookLocation(cfi: "epubcfi(/6/12!/4/2)"))
        #expect(spot.entry == 5)
        #expect(spot.steps == [.init(index: 2), .init(index: 1)])
        #expect(spot.cfi() == "epubcfi(/6/12!/4/2)")
    }

    @Test("Assertions stay, text nodes and character offsets drop out")
    func assertions() throws {
        let spot = try #require(BookLocation(cfi: "epubcfi(/6/4[kap2]!/4/2[kap2]/10[k2a5]/1:17)"))
        #expect(spot.entry == 1)
        #expect(
            spot.steps == [.init(index: 2), .init(index: 1, id: "kap2"), .init(index: 5, id: "k2a5")])
        #expect(spot.cfi() == "epubcfi(/6/4!/4/2[kap2]/10[k2a5])")
    }

    @Test("A range (foliate-js) is cut to the common parent path")
    func area() throws {
        let spot = try #require(BookLocation(cfi: "epubcfi(/6/14!/4/2/6,/1:0,/3:12)"))
        #expect(spot.entry == 6)
        #expect(spot.steps.map(\.index) == [2, 1, 3])
    }

    @Test("Special characters in an id are escaped and read back")
    func escaping() throws {
        let spot = BookLocation(entry: 0, steps: [.init(index: 2), .init(index: 3, id: "a[b]^c")])
        #expect(spot.cfi() == "epubcfi(/6/2!/4/6[a^[b^]^^c])")
        let read = try #require(BookLocation(cfi: spot.cfi()))
        #expect(read == spot)
    }

    @Test("A different spine step is adopted; nonsense yields nil")
    func spineAndNonsense() {
        #expect(BookLocation(entry: 2, steps: []).cfi(spine: 8) == "epubcfi(/8/6!)")
        #expect(BookLocation(cfi: "") == nil)
        #expect(BookLocation(cfi: "epubcfi(kaputt)") == nil)
    }

    @Test("The JavaScript for the jump carries the steps as JSON")
    func js() {
        let js = BookLocation.jsJump(to: [.init(index: 2), .init(index: 1, id: "kap2")])
        #expect(
            js.contains(#"{"index":2}"#) || js.contains(#"{"id":null,"index":2}"#)
                || js.contains(#""index":2"#))
        #expect(js.contains(#""kap2""#))
        #expect(js.contains("scrollToLocator"))
    }
}

@Suite("Spine card - OPF")
struct SpineCardTests {

    private func card() throws -> SpineCard {
        let epub = MockBook.epub(chapter: 3)
        let target = FileManager.default.temporaryDirectory.appending(path: "karte-\(UUID().uuidString).epub")
        try epub.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        // The OPF is stored in the archive - the raw text suffices for the map.
        let text = String(decoding: epub, as: UTF8.self)
        let start = try #require(text.range(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package"))
        let end = try #require(text.range(of: "</package>"))
        let opf = String(text[start.lowerBound..<end.upperBound])
        return try #require(SpineCard(opf: Data(opf.utf8), path: "OEBPS/content.opf"))
    }

    @Test("Spine is the third child of the package, the entries lie under OEBPS")
    func itemsäge() throws {
        let card = try card()
        #expect(card.spineStep == 6)
        #expect(card.entries == ["OEBPS/kap1.xhtml", "OEBPS/kap2.xhtml", "OEBPS/kap3.xhtml"])
    }

    @Test("Readium hrefs are found - encoded, with slash, with fragment")
    func hrefs() throws {
        let card = try card()
        #expect(card.entry(for: "OEBPS/kap2.xhtml") == 1)
        #expect(card.entry(for: "/OEBPS/kap3.xhtml#k3a2") == 2)
        #expect(card.entry(for: "OEBPS/kap%31.xhtml") == 0)
        #expect(card.entry(for: "OEBPS/nav.xhtml") == nil)
        #expect(card.href(for: 1) == "OEBPS/kap2.xhtml")
    }

    @Test("container.xml names the OPF; paths with .. are resolved")
    func container() {
        let xml = Data(
            """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="EPUB/paket.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)
        #expect(SpineCard.opfPath(container: xml) == "EPUB/paket.opf")
        #expect(SpineCard.resolved("../Text/k%201.xhtml", in: "EPUB/opf") == "EPUB/Text/k 1.xhtml")
    }
}
