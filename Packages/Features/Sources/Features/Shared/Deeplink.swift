import Foundation
import SourcesKit

/// The app's link scheme, used by the "Continue reading" widget. A link names a target by
/// name, as the probe does:
///
///     akari://titel/<provider>/<server>/<id>     the title detail
///     akari://serie/<provider>/<server>/<id>     the series detail
///     akari://lesen/<provider>/<server>/<id>     the reader of this title
///     akari://weiterlesen                        the most recently read title
///     akari://statistik                          Account, reading statistics (widget "Reading time")
///
/// `akari://einrichten?...` belongs to the setup code and is not read here. Server and
/// identifier are percent-encoded in the path: a Grimmory server is called
/// `books.example`, a Komga identifier carries hyphens.
enum Deeplink: Equatable {
    case title(TitleID)
    case series(SeriesID)
    case read(TitleID)
    case continueReading
    case statistics

    static let schema = "akari"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Deeplink.schema, let host = url.host()?.lowercased() else {
            return nil
        }
        let share = url.pathComponents.filter { $0 != "/" }
        switch (host, share.count) {
        case ("weiterlesen", 0):
            self = .continueReading
        case ("statistik", 0):
            self = .statistics
        case ("titel", 3), ("serie", 3), ("lesen", 3):
            guard let provider = Provider(rawValue: share[0]), !share[1].isEmpty, !share[2].isEmpty else {
                return nil
            }
            let source = SourceID(provider: provider, server: share[1])
            switch host {
            case "titel": self = .title(TitleID(source: source, id: share[2]))
            case "serie": self = .series(SeriesID(source: source, id: share[2]))
            default: self = .read(TitleID(source: source, id: share[2]))
            }
        default:
            return nil
        }
    }

    /// The link to a target; the inverse of `init(_:)`.
    var url: URL {
        var share = URLComponents()
        share.scheme = Deeplink.schema
        switch self {
        case .continueReading:
            share.host = "weiterlesen"
        case .statistics:
            share.host = "statistik"
        case .title(let k): share.host = "titel"; share.path = Deeplink.path(k.source, k.id)
        case .series(let k): share.host = "serie"; share.path = Deeplink.path(k.source, k.id)
        case .read(let k): share.host = "lesen"; share.path = Deeplink.path(k.source, k.id)
        }
        return share.url!
    }

    private static func path(_ source: SourceID, _ id: String) -> String {
        "/" + [source.provider.rawValue, source.server, id].joined(separator: "/")
    }
}
