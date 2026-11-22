import Bedrock
import Foundation
import SourcesKit
import Testing

@testable import AccountsKit

@Suite("Setup code and server address")
struct SetupCodeTests {

    @Test("Address: without a scheme it becomes https, trailing slash is dropped")
    func address() {
        #expect(ServerAddress.url(from: "comics.example")?.absoluteString == "https://comics.example")
        #expect(
            ServerAddress.url(from: " https://Comics.example/ ")?.absoluteString == "https://comics.example")
        #expect(
            ServerAddress.url(from: "http://192.0.2.183:25600")?.absoluteString
                == "http://192.0.2.183:25600")
        #expect(
            ServerAddress.url(from: "buecher.example/grimmory/")?.absoluteString
                == "https://buecher.example/grimmory")
        #expect(ServerAddress.url(from: "") == nil)
        #expect(ServerAddress.url(from: "   ") == nil)
        #expect(ServerAddress.url(from: "ftp://x.example") == nil)
    }

    @Test("Round trip: same content, same link")
    func roundTrip() throws {
        let snapshot = CertificateFingerprint(value: String(repeating: "4911402F", count: 8))
        let code = SetupCode(
            server: [
                .komga: URL(string: "https://comics.example")!,
                .grimmory: URL(string: "https://buecher.example")!,
                .audiobookshelf: URL(string: "https://hoerbuch.example")!,
            ], fingerprint: snapshot)
        let link = code.url.absoluteString
        #expect(link.hasPrefix("akari://einrichten?komga=https://comics.example&grimmory="))
        #expect(link.hasSuffix("&zertifikat=" + snapshot.value))
        let read = try #require(SetupCode(code.url))
        #expect(read == code)
        #expect(read.computer == ["buecher.example", "comics.example", "hoerbuch.example"])
    }

    @Test("Names per provider: written, read back, dropped without an address")
    func names() throws {
        let code = SetupCode(
            server: [
                .komga: URL(string: "https://comics.example")!,
                .grimmory: URL(string: "https://buecher.example")!,
            ],
            names: [.komga: "robin@example.test", .grimmory: "robin"])
        let link = code.url.absoluteString
        #expect(link.contains("komga-name=robin@example.test"))
        #expect(link.contains("grimmory-name=robin"))
        let read = try #require(SetupCode(code.url))
        #expect(read == code)
        // A name for a provider that has no address is no suggestion.
        let partial = try #require(
            SetupCode(text: "akari://einrichten?komga=comics.example&audiobookshelf-name=robin"))
        #expect(partial.names.isEmpty)
    }

    @Test("A catalog and a WebDAV folder in the code: paths stay, `webdav=` is read")
    func catalogAndFolder() throws {
        let code = try #require(
            SetupCode(
                text:
                    "akari://einrichten?opds=https://comics.example/opds/v1.2/catalog&webdav=https://nextcloud.example/remote.php/dav/files/leser/B%C3%BCcher&webdav-name=leser"
            ))
        #expect(code.server[.webdav]?.path(percentEncoded: false) == "/remote.php/dav/files/leser/Bücher")
        #expect(code.server[.opds]?.path() == "/opds/v1.2/catalog")
        #expect(code.names[.webdav] == "leser")
        #expect(
            code.url.absoluteString.contains(
                "webdav=https://nextcloud.example/remote.php/dav/files/leser/B%25C3%25BCcher")
                || code.url.absoluteString.contains(
                    "webdav=https://nextcloud.example/remote.php/dav/files/leser/B%C3%BCcher")
        )
        #expect(SetupCode(code.url) == code)
    }

    @Test("A link with only one server, without fingerprint, tolerant of letter case")
    func singleServer() throws {
        let code = try #require(SetupCode(text: " AKARI://einrichten?Komga=comics.example "))
        #expect(code.server == [.komga: URL(string: "https://comics.example")!])
        #expect(code.fingerprint == nil)
    }

    @Test("What is no setup link does not become one")
    func fremd() {
        #expect(SetupCode(text: "https://comics.example") == nil)
        #expect(SetupCode(text: "akari://lesen?komga=comics.example") == nil)
        #expect(SetupCode(text: "akari://einrichten?zertifikat=ABCD") == nil)
        #expect(SetupCode(text: "akari://einrichten?plex=x.example") == nil)
        #expect(SetupCode(text: "nicht mal ein link") == nil)
    }

    @Test("A fingerprint with separators is read, one that is too short is not")
    func snapshot() throws {
        let withSpaces =
            "akari://einrichten?komga=comics.example&zertifikat="
            + "4911 402F 58E1 0C64 EB29 3CAC 188D 7270 D57D 205A 45DA 85C1 7588 D9DC C421 2265"
        let code = try #require(
            SetupCode(text: withSpaces.replacingOccurrences(of: " ", with: "%20")))
        #expect(code.fingerprint?.value.count == 64)
        #expect(code.fingerprint?.value.hasPrefix("4911402F") == true)
        let short = try #require(
            SetupCode(text: "akari://einrichten?komga=comics.example&zertifikat=4911"))
        #expect(short.fingerprint == nil)
    }

    @Test("Add device: share link and color travel in the link, even without servers")
    func addDevice() throws {
        let sharing = URL(string: "https://www.icloud.com/share/0abc#Alex")!
        let code = SetupCode(
            server: [.komga: URL(string: "https://comics.example")!], names: [.komga: "leser@comics.example"],
            person: "Alex", sharing: sharing, color: "indigo")
        let read = try #require(SetupCode(code.url))
        #expect(read == code && read.sharing == sharing && read.color == "indigo")
        #expect(code.url.absoluteString.hasPrefix("akari://einrichten?"))
        let shareOnly = try #require(
            SetupCode(
                text: "akari://einrichten?person=Alex&freigabe="
                    + sharing.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        #expect(shareOnly.server.isEmpty && shareOnly.sharing == sharing)
    }
}
