import SwiftUI

/// The zoom from cover to detail. What you tap becomes the next screen: the cover grows
/// into the detail and shrinks back into place under the finger when swiping back.
///
/// Every stack with ``SwiftUI/View/targets()`` has a namespace; every ``Cover`` with a
/// target registers there as a source, and title and series detail zoom from it. If
/// there is no source (deep link, search without cover), iOS uses the usual transition.
/// With "Reduce Motion" it stays a plain push.
struct ZoomSpaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomSpace: Namespace.ID? {
        get { self[ZoomSpaceKey.self] }
        set { self[ZoomSpaceKey.self] = newValue }
    }
}

extension View {
    /// Makes this view the zoom source for `target`; without a target or namespace
    /// nothing changes.
    func zoomSource(_ target: Target?) -> some View {
        modifier(ZoomSource(target: target))
    }
}

private struct ZoomSource: ViewModifier {

    let target: Target?
    @Environment(\.zoomSpace) private var space

    func body(content: Content) -> some View {
        if let target, let space {
            content.matchedTransitionSource(id: target, in: space)
        } else {
            content
        }
    }
}

/// The targets of a stack, with their own namespace for the zoom.
struct TargetStack: ViewModifier {

    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.zoomSpace, space)
            .navigationDestination(for: Target.self) { target in
                TargetStack.viewMode(target)
                    // Covers in the detail (volumes of a series) keep zooming too.
                    .environment(\.zoomSpace, space)
                    .modifier(ZoomTarget(target: target, space: space, active: !reduceMotion))
            }
    }

    @ViewBuilder
    static func viewMode(_ target: Target) -> some View {
        switch target {
        case .title(let identifier): TitleDetailView(identifier: identifier)
        case .series(let identifier): SeriesDetailView(identifier: identifier)
        case .genre(let kind, let genre): GenreView(kind: kind, genre: genre)
        case .allGenres(let kind): AllGenresView(kind: kind)
        case .continueReading: ContinueReadingList()
        case .continueListening: ContinueReadingList(listen: true)
        case .new: NewList()
        case .stalled: StalledList()
        case .saved: SavedView()
        case .device: DeviceView()
        case .author(let name): AuthorView(name: name)
        case .publisher(let name): PublisherView(name: name)
        case .collection(let identifier): CollectionView(identifier: identifier)
        case .allCollections(let kind): AllCollectionsView(kind: kind)
        }
    }
}

/// Titles and series zoom; all other targets push as usual.
private struct ZoomTarget: ViewModifier {

    let target: Target
    let space: Namespace.ID
    let active: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
            switch target {
            case .title where active, .series where active:
                content.navigationTransition(.zoom(sourceID: target, in: space))
            default:
                content
            }
        #else
            content
        #endif
    }
}
