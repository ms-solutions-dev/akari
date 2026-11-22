import Foundation

/// Known OPDS servers: whoever picks "Calibre-Web" types only the server address, and Akari
/// appends the catalog path, since hardly anyone knows where the catalog lives.
///
/// **Verified, not guessed:** Calibre-Web `cps/opds.py` (`@opds.route("/opds")`), Calibre
/// Content Server per its manual `/opds`, Stump `apps/server/src/routers/opds` (`/opds` + `/v1.2`
/// + `/catalog`). Komga, Grimmory and Kavita are left out on purpose: they have their own
/// integrations with reading progress, and OPDS would be the worse route for them.
enum OpdsTemplate: String, CaseIterable, Identifiable {
    case other = "andere", calibreWeb, calibre, stump

    var id: String { rawValue }

    /// The catalog path Akari appends to a bare server address; `nil` for "Other".
    var path: String? {
        switch self {
        case .other: nil
        case .calibreWeb, .calibre: "/opds"
        case .stump: "/opds/v1.2/catalog"
        }
    }

    var lookupKey: String { "account.opds.template." + rawValue }

    /// The address used for sign-in: if the input already has a path it is used as is,
    /// so anyone who knows the catalog is not overruled. Otherwise the template's path is added.
    /// "books.example.com" -> "books.example.com/opds", "https://x.example:8083/" ->
    /// "https://x.example:8083/opds", "x.example/my/catalog" stays.
    static func catalogAddress(_ input: String, template: OpdsTemplate) -> String {
        var address = input.trimmingCharacters(in: .whitespaces)
        guard let path = template.path, !address.isEmpty else { return address }
        while address.hasSuffix("/") { address.removeLast() }
        var withoutScheme = Substring(address)
        if let schema = withoutScheme.range(of: "://") { withoutScheme = withoutScheme[schema.upperBound...] }
        guard !withoutScheme.contains("/") else { return address }
        return address + path
    }
}
