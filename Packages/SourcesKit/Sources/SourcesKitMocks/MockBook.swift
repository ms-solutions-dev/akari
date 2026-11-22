import Foundation

/// A built EPUB for previews and tests: three chapters, table of contents,
/// one footnote — small enough to build in memory, real enough for
/// Readium to open it and a state as CFI to arise from it.
///
/// Built rather than recorded: a book from the library may not go into the repo,
/// and a recording could not be read. The chapters carry `id`s, so that
/// the CFI test sees assertions (`[kap2]`) as foliate-js writes them.
public enum MockBook {

    /// The EPUB as bytes — a ZIP without compression, `mimetype` first, as the
    /// standard wants.
    /// - Parameter glossary: with a glossary at the end — terms that occur in the
    ///   sentences; the tests count three chapters, so it is off.
    public static func epub(
        name: String = "Die Probe", chapter count: Int = 3, glossary with: Bool = false
    ) -> Data {
        var chapter = (1...max(count, 1)).map { n in
            (file: "kap\(n).xhtml", title: "Kapitel \(n)", body: chapterBody(n))
        }
        if with { chapter.append((file: "glossar.xhtml", title: "Glossar", body: glossary)) }
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opf(name: name, chapter: chapter).utf8)),
            ("OEBPS/nav.xhtml", Data(nav(chapter: chapter).utf8)),
        ]
        for k in chapter {
            entries.append(("OEBPS/\(k.file)", Data(page(title: k.title, body: k.body).utf8)))
        }
        return ZipWriter.archive(entries)
    }

    /// How many paragraphs a chapter has — for tests that expect a path.
    public static let paragraphsPerChapter = 14

    private static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    private static func opf(name: String, chapter: [(file: String, title: String, body: String)]) -> String {
        let manifest = chapter.enumerated().map {
            "    <item id=\"kap\($0.offset + 1)\" href=\"\($0.element.file)\" media-type=\"application/xhtml+xml\"/>"
        }
        .joined(separator: "\n")
        let spine = chapter.enumerated().map { "    <itemref idref=\"kap\($0.offset + 1)\"/>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:akari-attrappe-\(name.hashValue.magnitude)</dc:identifier>
                <dc:title>\(name)</dc:title>
                <dc:language>de</dc:language>
                <meta property="dcterms:modified">2026-09-17T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifest)
              </manifest>
              <spine>
            \(spine)
              </spine>
            </package>
            """
    }

    private static func nav(chapter: [(file: String, title: String, body: String)]) -> String {
        let listItems = chapter.map { "      <li><a href=\"\($0.file)\">\($0.title)</a></li>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Inhalt</title></head>
            <body>
              <nav epub:type="toc" id="toc">
                <h1>Inhalt</h1>
                <ol>
            \(listItems)
                </ol>
              </nav>
            </body>
            </html>
            """
    }

    private static func page(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(title)</title></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Fourteen paragraphs per chapter, the second with a footnote — enough text for
    /// several pages on a phone.
    private static func chapterBody(_ n: Int) -> String {
        var lines = ["<section id=\"kap\(n)\">", "<h1>Kapitel \(n)</h1>"]
        for a in 1...paragraphsPerChapter {
            let sentence = sentences[(a + n) % sentences.count]
            let footnote = (n == 2 && a == 3) ? " <a epub:type=\"noteref\" href=\"#fn\(n)\">1</a>" : ""
            lines.append("<p id=\"k\(n)a\(a)\">\(sentence) \(sentence.lowercased())\(footnote)</p>")
        }
        if n == 2 {
            lines.append(
                "<aside epub:type=\"footnote\" id=\"fn2\"><p>Eine Fußnote: Sie erscheint als Blatt über dem Text, nicht als Sprung.</p></aside>"
            )
        }
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// The glossary: alphabetical, "Term: explanation" — the most common form in real
    /// books.
    static let glossary = """
        <section id="glossar">
        <h1>Glossar</h1>
        <p>Bahnsteig: Der lange Steinstreifen neben den Gleisen, auf dem man wartet, bis der Zug kommt.</p>
        <p>Brief: Ein gefaltetes Blatt in einem Umschlag; im Ort kam er zweimal die Woche.</p>
        <p>Fähre: Das flache Boot, das den Fluss zwischen Ort und Insel übersetzt, morgens und abends.</p>
        <p>Laterne: Eine Gaslampe an einem Pfosten; im Ort brannten noch sieben davon.</p>
        <p>Moos: Das grüne Polster auf altem Holz und Stein, das den Regen hält.</p>
        <p>Tor: Der Eingang zum alten Hof, aus Eiche, seit dem Krieg nicht mehr geschlossen.</p>
        <p>Uhr: Die Bahnhofsuhr, die vorging; niemand ließ sie richten.</p>
        <p>Zug: Kam einmal am Tag, und wer ihn verpasste, blieb.</p>
        </section>
        """

    private static let sentences = [
        "Der Regen hatte aufgehört, als sie das Tor erreichten, und die Straße glänzte im Licht der wenigen Laternen.",
        "Niemand sprach, während die Fähre ablegte; das Wasser schlug in kurzen Wellen gegen den Rumpf.",
        "Er hatte den Brief dreimal gelesen und verstand ihn beim dritten Mal weniger als beim ersten.",
        "Im Garten stand noch der Stuhl vom Sommer, das Holz grau geworden, die Lehne voller Moos.",
        "Die Uhr über dem Bahnsteig ging vor, das wusste jeder im Ort, und keiner ließ sie richten.",
        "Sie zählte die Stufen, wie sie es als Kind getan hatte, und kam auf eine mehr als damals.",
        "Vom Dach aus sah man bis zum Fluss, an klaren Tagen bis zu den Hügeln dahinter.",
        "Der Hund schlief unter dem Tisch und hob den Kopf nur, wenn jemand die Tür öffnete.",
    ]
}

/// A ZIP archive without compression — header, content, central directory, end.
/// That is enough for an EPUB: Readium's archive reader reads stored entries.
enum ZipWriter {

    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let checksum = crc32(data)
            let offset = UInt32(archive.count)
            archive.append(integer(UInt32(0x0403_4B50)))
            archive.append(integer(UInt16(20)))
            archive.append(integer(UInt16(0)))
            archive.append(integer(UInt16(0)))
            archive.append(integer(UInt16(0)))
            archive.append(integer(UInt16(0x21)))
            archive.append(integer(checksum))
            archive.append(integer(UInt32(data.count)))
            archive.append(integer(UInt32(data.count)))
            archive.append(integer(UInt16(nameBytes.count)))
            archive.append(integer(UInt16(0)))
            archive.append(nameBytes)
            archive.append(data)

            centralDirectory.append(integer(UInt32(0x0201_4B50)))
            centralDirectory.append(integer(UInt16(20)))
            centralDirectory.append(integer(UInt16(20)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt16(0x21)))
            centralDirectory.append(integer(checksum))
            centralDirectory.append(integer(UInt32(data.count)))
            centralDirectory.append(integer(UInt32(data.count)))
            centralDirectory.append(integer(UInt16(nameBytes.count)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt16(0)))
            centralDirectory.append(integer(UInt32(0)))
            centralDirectory.append(integer(offset))
            centralDirectory.append(nameBytes)
        }
        let startTime = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.append(integer(UInt32(0x0605_4B50)))
        archive.append(integer(UInt16(0)))
        archive.append(integer(UInt16(0)))
        archive.append(integer(UInt16(entries.count)))
        archive.append(integer(UInt16(entries.count)))
        archive.append(integer(UInt32(centralDirectory.count)))
        archive.append(integer(startTime))
        archive.append(integer(UInt16(0)))
        return archive
    }

    private static func integer(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private static func integer(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
