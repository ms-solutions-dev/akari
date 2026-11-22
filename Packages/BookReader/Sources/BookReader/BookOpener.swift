import Bedrock
import Foundation
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer

/// Opens a file with Readium: detect the format, open the container, read the
/// package document. The result is a `Publication` and the
/// ``SpineCard`` for the CFIs.
public enum BookOpener {

    public struct Opened: @unchecked Sendable {
        public let publication: Publication
        public let spineCard: SpineCard?
        public let isPdf: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case noFile
        case notReadable(String)

        public var description: String {
            switch self {
            case .noFile: "no file"
            case .notReadable(let reason): reason
            }
        }
    }

    /// - Parameter box: sees every resource as it loads - for the
    ///   glossary marking in the chapter text (``GlossaryBox``).
    public static func open(_ file: URL, box: GlossaryBox? = nil) async throws -> Opened {
        let start = Date()
        guard let url = FileURL(url: file) else { throw Failure.noFile }
        let http = DefaultHTTPClient()
        let holer = AssetRetriever(httpClient: http)
        let asset: Asset
        switch await holer.retrieve(url: url) {
        case .success(let a): asset = a
        case .failure(let failure): throw Failure.notReadable(String(describing: failure))
        }
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: http, assetRetriever: holer, pdfFactory: DefaultPDFDocumentFactory()))
        let publication: Publication
        let result = await opener.open(
            asset: asset, allowUserInteraction: false,
            onCreatePublication: { _, container, _ in
                if let box { container = container.map { box.transform($0, $1) } }
            })
        switch result {
        case .success(let p): publication = p
        case .failure(let failure): throw Failure.notReadable(String(describing: failure))
        }
        let isPdf = publication.conforms(to: .pdf)
        let card = isPdf ? nil : await spineCard(publication)
        Diagnostics.step(
            "Book opened: \(publication.readingOrder.count) entries, \(isPdf ? "PDF" : "EPUB")"
                + (card.map { ", spine /\($0.spineStep) with \($0.entries.count)" } ?? ""),
            since: start, area: "Reader")
        return Opened(publication: publication, spineCard: card, isPdf: isPdf)
    }

    /// The map from `META-INF/container.xml` and the OPF - `nil` if either is
    /// missing; then Readium's reading order and `/6` apply.
    static func spineCard(_ publication: Publication) async -> SpineCard? {
        guard
            let container = try? await publication.get(RelativeURL(string: "META-INF/container.xml")!)?.read()
                .get(),
            let path = SpineCard.opfPath(container: container),
            let opfURL = RelativeURL(string: path),
            let opf = try? await publication.get(opfURL)?.read().get()
        else { return nil }
        return SpineCard(opf: opf, path: path)
    }
}
