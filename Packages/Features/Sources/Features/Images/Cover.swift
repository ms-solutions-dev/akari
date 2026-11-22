import DesignSystem
import Library
import OfflineStore
import SourcesKit
import SwiftUI

/// A cover from the source, in a frame, with a placeholder per kind, loaded through the
/// ``ImageLoader`` with the source's headers and transport.
///
/// **Cancellation is the point:** `task(id:)` cancels as soon as the tile scrolls out of
/// view; when flicking through 930 books, a hundred fetches for covers nobody sees would
/// otherwise run.
struct Cover: View {

    let address: URL?
    let source: SourceID
    let kind: Kind
    /// The width in points; for books and manga the height is 1.5 times that, for
    /// audiobooks the same (square).
    let width: CGFloat
    /// Title and author for the placeholder while there is no image.
    var caption: (title: String, author: String?)?
    /// Where a tap on this cover leads; the cover is then the source of the zoom
    /// transition to the detail. Title and series set it themselves.
    var target: Target?
    /// Reports the loaded image, for the glow behind hero and detail header.
    var onImage: (@MainActor (CGImage) -> Void)?

    @Environment(LibraryService.self) private var inventory
    @Environment(\.imageTransport) private var transport
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?
    /// The address ``image`` belongs to. If it changes for the same view (the hero on
    /// Start shows another title), the old image no longer applies.
    @State private var imageAddress: URL?
    /// The fetch is done; only then is the ``TitlePlaceholder`` shown, if no image arrived.
    @State private var queried = false

    init(
        _ address: URL?, source: SourceID, kind: Kind, width: CGFloat,
        caption: (title: String, author: String?)? = nil, target: Target? = nil,
        onImage: (@MainActor (CGImage) -> Void)? = nil
    ) {
        self.address = address
        self.source = source
        self.kind = kind
        self.width = width
        self.caption = caption
        self.target = target
        self.onImage = onImage
    }

    /// Convenience initializer from a title or a series.
    ///
    /// - Parameter upfront: an already loaded image that is shown from the first frame.
    ///   The book cover in the ``BookReaderSheet`` is a second view of the same cover and
    ///   would otherwise show the ``TitlePlaceholder`` for one frame.
    init(
        _ title: Title, width: CGFloat, upfront: CGImage? = nil,
        onImage: (@MainActor (CGImage) -> Void)? = nil
    ) {
        self.init(
            title.cover, source: title.identifier.source, kind: title.kind, width: width,
            caption: (title.name, title.authors.first), target: .title(title.identifier), onImage: onImage)
        _image = State(initialValue: upfront)
        _imageAddress = State(initialValue: upfront == nil ? nil : title.cover)
    }

    init(_ series: Series, width: CGFloat, onImage: (@MainActor (CGImage) -> Void)? = nil) {
        self.init(
            series.cover, source: series.identifier.source, kind: series.kind, width: width,
            caption: (series.name, series.authors.first), target: .series(series.identifier),
            onImage: onImage)
    }

    private var ownImage: CGImage? { imageAddress == address ? image : nil }

    var body: some View {
        // If the state has no image yet but memory does, use that right away, so a newly
        // created tile shows its cover in the first frame. The `task` below only runs one
        // pass later.
        let points = Cover.pixels(width: width, displayScale: displayScale)
        let visible = ownImage ?? address.flatMap { ImageLoader.shared.saved($0, pixels: points) }
        // **The image never determines its own size:** `Color.clear` does the measuring
        // and the image sits on top. Otherwise a square audiobook cover proposes its full
        // width and pushes the card out of view.
        // It is also not cropped: a cover that is not 2:3 fills the area completely
        // instead of losing its edge text.
        CoverFrame(
            aspectRatio: kind.isAudible ? CoverFormat.square : CoverFormat.portrait,
            depth: width < 70 ? .flat : .normal
        ) {
            Color.clear.overlay {
                if let visible {
                    Image(decorative: visible, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else if address != nil, !queried {
                    // While the image loads: only the frame's surface. The colored
                    // placeholder used to show during loading too and flashed for one
                    // frame before every cover.
                    Color.clear
                } else if let caption, !kind.isAudible {
                    // Title and author on a color derived from the title instead of a gray surface.
                    TitlePlaceholder(title: caption.title, author: caption.author)
                } else {
                    CoverPlaceholder(glyph: Cover.glyph(kind))
                }
            }
            .animation(Motion.short(reduceMotion), value: visible == nil)
        }
        .frame(width: width)
        .zoomSource(target)
        // If the image is already in memory, the caller learns of it before the first
        // frame, without animation. Otherwise the glow appeared one pass later and
        // visibly faded in.
        .onAppear {
            guard ownImage == nil, let address,
                let saved = ImageLoader.shared.saved(
                    address, pixels: Cover.pixels(width: width, displayScale: displayScale))
            else { return }
            var silent = Transaction()
            silent.disablesAnimations = true
            withTransaction(silent) { onImage?(saved) }
        }
        .task(id: address) {
            guard let address else { return }
            if imageAddress != address { queried = false }
            let new = await ImageLoader.shared.image(
                address, headerLines: inventory.headerLines(source), pixels: points,
                transport: transport(source.provider))
            guard !Task.isCancelled else { return }
            queried = true
            // A failure does not clear an image that is already showing (`upfront`).
            guard let new else { return }
            image = new
            imageAddress = address
            onImage?(new)
        }
    }

    /// The longer edge in pixels, rounded to 80 so nearby sizes share the same image;
    /// otherwise the cache holds three versions of the same cover: on iPhone (3x) 110
    /// and 118 pt fall on 560, on iPad (2x) 140, 150 and 160 pt on 480 (``TileMetrics``).
    static func pixels(width: CGFloat, displayScale: CGFloat) -> Int {
        Int((width * 1.5 * displayScale / 80).rounded(.up)) * 80
    }

    static func glyph(_ kind: Kind) -> String {
        switch kind {
        case .manga: "book.pages"
        case .book: "book.closed"
        case .audiobook: "headphones"
        case .podcast: "antenna.radiowaves.left.and.right"
        }
    }
}

/// The per-provider transport for images: in operation from the `AccountRegistry`
/// (same session, same certificate guard), otherwise the shared session.
struct ImageTransportKey: EnvironmentKey {
    static let defaultValue: @Sendable (Provider) -> any Transport = { _ in URLSession.shared }
}

extension EnvironmentValues {
    var imageTransport: @Sendable (Provider) -> any Transport {
        get { self[ImageTransportKey.self] }
        set { self[ImageTransportKey.self] = newValue }
    }
}
