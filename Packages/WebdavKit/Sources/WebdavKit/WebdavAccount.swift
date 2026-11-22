import Foundation
import SourcesKit

/// A WebDAV account: the address of a folder and name and password for Basic Auth.
///
/// **The password stays** — as with OPDS there is no key and no token; every request carries
/// name and password. For Nextcloud an app password (Settings → Security) is best, not the
/// login password. It lives in the Keychain like the other kits' secrets, never in a file.
///
/// **The title is the folder name:** A WebDAV folder has no feed title; the last path part
/// ("Bücher") is what the account sheet shows.
public struct WebdavAccount: Sendable, Codable, Hashable {
    /// The address of the folder, with a trailing slash — for Nextcloud
    /// `https://nextcloud.example/remote.php/dav/files/<name>/<folder>/`.
    public let folder: URL
    public let username: String
    public let password: String
    /// The last path part of the folder, percent-encoded characters turned back.
    public let title: String

    public init(folder: URL, username: String, password: String) {
        self.folder = WebdavAccount.withTrailingSlash(folder)
        self.username = username
        self.password = password
        self.title = WebdavAccount.folderName(self.folder)
    }

    public var server: URL { folder }

    /// Two folders on the same host are two sources — hence the folder is part of the key:
    /// `nextcloud.example · Bücher`. The Nextcloud prefix `remote.php/dav/files/<name>` drops out;
    /// it is in every address and says nothing.
    public var identifier: SourceID {
        let host = folder.host() ?? folder.absoluteString
        let path = WebdavAccount.shortPath(folder)
        return SourceID(provider: .webdav, server: path.isEmpty ? host : host + " · " + path)
    }

    /// What a folder can do: series (from folders and names), keeping (the file is the way). No
    /// reading state on the server, no saved list, no collections.
    public var capabilities: Capabilities { [.seriesList, .keep] }

    var headerLines: [String: String] {
        guard !username.isEmpty else { return [:] }
        return ["Authorization": "Basic " + Data((username + ":" + password).utf8).base64EncodedString()]
    }

    /// A folder ends in `/` — otherwise `appending(path:)` attaches the file to the folder name
    /// instead of below it, and some servers answer with 301.
    static func withTrailingSlash(_ url: URL) -> URL {
        url.path().hasSuffix("/") ? url : url.appending(path: "", directoryHint: .isDirectory)
    }

    static func folderName(_ url: URL) -> String {
        let share = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        return share.last ?? url.host() ?? "WebDAV"
    }

    /// The path without the Nextcloud prefix (`remote.php/dav/files/<name>`, `remote.php/webdav`)
    /// and ownCloud, slashes as middle dots.
    static func shortPath(_ url: URL) -> String {
        var share = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        if share.count >= 4, share[0] == "remote.php", share[1] == "dav", share[2] == "files" {
            share.removeFirst(4)
        } else if share.count >= 2, share[0] == "remote.php", share[1] == "webdav" {
            share.removeFirst(2)
        } else if share.count >= 3, share[0] == "dav", share[1] == "files" {
            share.removeFirst(3)
        } else if share.first == "webdav" || share.first == "dav" {
            share.removeFirst()
        }
        return share.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case folder = "ordner"
        case username = "benutzername"
        case password = "passwort"
        case title = "titel"
    }
}
