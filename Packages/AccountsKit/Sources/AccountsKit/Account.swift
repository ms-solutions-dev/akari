import AudiobookshelfKit
import Foundation
import GrimmoryKit
import KavitaKit
import KomgaKit
import OpdsKit
import SourcesKit
import WebdavKit

/// A signed-in account — one of the three, under one roof.
///
/// The kits each know their account (key, token pair, long-lived token); the screens
/// only want server, name and capabilities from it. The roof holds the cases together
/// and is what lies in the keychain.
public enum Account: Sendable, Codable, Hashable {
    case komga(KomgaAccount)
    case grimmory(GrimmoryAccount)
    case audiobookshelf(AudiobookshelfAccount)
    /// Kavita — an auth key like Komga, no token pair.
    case kavita(KavitaAccount)
    /// An OPDS catalog — name and password stay, there is no key.
    case opds(OpdsAccount)
    /// A WebDAV folder — name and password as with OPDS, the folder is the title.
    case webdav(WebdavAccount)

    public var provider: Provider {
        switch self {
        case .komga: .komga
        case .grimmory: .grimmory
        case .audiobookshelf: .audiobookshelf
        case .kavita: .kavita
        case .opds: .opds
        case .webdav: .webdav
        }
    }

    public var server: URL {
        switch self {
        case .komga(let k): k.server
        case .grimmory(let k): k.server
        case .audiobookshelf(let k): k.server
        case .kavita(let k): k.server
        case .opds(let k): k.catalog
        case .webdav(let k): k.folder
        }
    }

    /// The name under which the account runs on the server — for Komga the email.
    public var username: String {
        switch self {
        case .komga(let k): k.email
        case .grimmory(let k): k.username
        case .audiobookshelf(let k): k.username
        case .kavita(let k): k.username
        case .opds(let k): k.username
        case .webdav(let k): k.username
        }
    }

    public var identifier: SourceID {
        switch self {
        case .komga(let k): k.identifier
        case .grimmory(let k): k.identifier
        case .audiobookshelf(let k): k.identifier
        case .kavita(let k): k.identifier
        case .opds(let k): k.identifier
        case .webdav(let k): k.identifier
        }
    }

    public var capabilities: Capabilities {
        switch self {
        case .komga(let k): k.capabilities
        case .grimmory(let k): k.capabilities
        case .audiobookshelf(let k): k.capabilities
        case .kavita(let k): k.capabilities
        case .opds(let k): k.capabilities
        case .webdav(let k): k.capabilities
        }
    }

    /// A name the account brings itself — the title of the OPDS catalog ("Komga OPDS
    /// catalog"), the folder name for WebDAV ("Books"); the servers are named after their
    /// kind, here `nil`.
    public var displayName: String? {
        switch self {
        case .opds(let k): k.title.isEmpty ? nil : k.title
        case .webdav(let k): k.title.isEmpty ? nil : k.title
        default: nil
        }
    }

    /// Whether the account may fetch files — the rights hint in the accounts sheet
    /// ("may not keep on books.example — reading still works").
    public var mayKeep: Bool { capabilities.contains(.keep) }
}

/// An account with what the accounts sheet shows besides: when and on which device
/// the key was created ("Key created on … on this device · Remove").
public struct AccountEntry: Sendable, Codable, Hashable {
    public var account: Account
    public let createdAt: Date
    public let device: String

    public init(account: Account, createdAt: Date = Date(), device: String) {
        self.account = account
        self.createdAt = createdAt
        self.device = device
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case account = "konto"
        case createdAt = "erstellt"
        case device = "geraet"
    }
}
