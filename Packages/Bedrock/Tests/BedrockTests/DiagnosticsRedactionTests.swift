import Foundation
import Testing

@testable import Bedrock

/// Tests what gets from an address into the log.
///
/// The log is the only place where an error on the television can be traced, and
/// it is therefore passed on. If the credentials are in it, they are given away:
/// providers block an account that comes from several places, and the viewer
/// loses not one show but television altogether.
///
/// The addresses here are not invented examples but the forms in which IPTV
/// providers actually hand out their addresses.
@Suite("Addresses in the log")
struct DiagnosticsRedactionTests {

    @Test("The credentials in the channel list address are not in the log")
    func m3uCredentialsAreDropped() throws {
        // The usual form of an M3U address. The user enters it as one whole line, and
        // user name and password are in the query.
        let url = try #require(
            URL(string: "http://panel.example:8080/get.php?username=benutzer&password=geheim&type=m3u")
        )

        let logged = Diagnostics.loggable(url)

        #expect(!logged.contains("geheim"))
        #expect(!logged.contains("benutzer"))
        // And what remains must still be of use: without host and path it could no
        // longer be said which request failed.
        #expect(logged == "http://panel.example:8080/get.php")
    }

    @Test("The credentials in the program guide address are not in the log")
    func guideCredentialsAreDropped() throws {
        // The same form for the XMLTV file. It is the second address logged in
        // operation, and the one where the rule was forgotten last.
        let url = try #require(
            URL(string: "http://panel.example:8080/xmltv.php?username=benutzer&password=geheim")
        )

        #expect(Diagnostics.loggable(url) == "http://panel.example:8080/xmltv.php")
    }

    @Test("Credentials before the host name are dropped as well")
    func inlineCredentialsAreDropped() throws {
        // The other common notation. It is not in the query, and whoever removes only
        // the query overlooks it.
        let url = try #require(URL(string: "http://benutzer:geheim@server.example/liste.m3u"))

        let logged = Diagnostics.loggable(url)

        #expect(!logged.contains("geheim"))
        #expect(logged == "http://server.example/liste.m3u")
    }

    @Test("An address without credentials stays complete")
    func harmlessAddressSurvives() throws {
        // The counter test. If everything were shortened across the board, the log
        // would lose its purpose: a failure fetching `/xmltv.xml` would look like any
        // other.
        let url = try #require(URL(string: "http://media.example:8096/epg/xmltv.xml"))

        #expect(Diagnostics.loggable(url) == "http://media.example:8096/epg/xmltv.xml")
    }

    @Test("A local file keeps its path in the log")
    func localFileKeepsItsPath() throws {
        // A file address has no host name. The user also keeps their XMLTV file
        // locally, and then the path is the only usable information; whoever shortened
        // to host and port across the board would log the same empty line for every
        // file.
        let file = try #require(URL(string: "file:///var/tmp/epg.xml"))

        #expect(Diagnostics.loggable(file) == "file:///var/tmp/epg.xml")
    }
}
