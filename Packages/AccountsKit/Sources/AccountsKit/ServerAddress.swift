import Foundation

/// Turns what someone types into the address field into a server address.
///
/// "comics.example", "https://comics.example/", "comics.example:8443" — all the same
/// target. Without a scheme `https` is assumed, because the three servers speak
/// nothing else; whoever wants `http` writes it. The path stays, without a slash at
/// the end, so that `appending(path:)` in the kit does not build doubled ones.
public enum ServerAddress {

    public static func url(from text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        guard var share = URLComponents(string: t), let host = share.host, !host.isEmpty,
            share.scheme == "https" || share.scheme == "http"
        else { return nil }
        share.host = host.lowercased()
        share.query = nil
        share.fragment = nil
        return share.url
    }
}
