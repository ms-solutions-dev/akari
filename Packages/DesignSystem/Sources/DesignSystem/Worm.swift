import CoreGraphics
import ImageIO
import SwiftUI

/// The bookworm - a companion character. A book illustration
/// with two heads, depending on the pose: flat cap when he accompanies calmly, scholar's hair
/// when something happens. Cut out so he stands on every theme, light and dark.
///
/// He only appears where an empty state or a success may be friendly. An error stays
/// an error with a glyph - the worm does not excuse a server.
public struct Worm: View {

    /// What the worm is doing right now.
    public enum Pose: String, CaseIterable, Sendable {
        /// Tips his cap - first start, welcome.
        case welcome = "willkommen"
        /// Reads a book - empty library, nothing saved, empty states.
        case read = "lesen"
        /// Cheers with a bookmark ribbon - "Connected!", book finished.
        case cheer = "jubel"
        /// Searches with a magnifier - nothing found.
        case seek = "suchen"
    }

    private let pose: Pose
    private let edge: CGFloat

    /// - Parameters:
    ///   - pose: what the worm does; reads by default.
    ///   - edge: the side length in points.
    public init(_ pose: Pose = .read, edge: CGFloat = 96) {
        self.pose = pose
        self.edge = edge
    }

    public var body: some View {
        Group {
            if let image = Worm.images[pose] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "face.smiling")
            }
        }
        .frame(width: edge, height: edge)
        .modifier(Lively(pose: pose))
        .accessibilityHidden(true)
    }

    /// Loaded once per pose. The images are 480 px: enough for 160 pt at @3x.
    private static let images: [Pose: CGImage] = Dictionary(
        uniqueKeysWithValues: Pose.allCases.compactMap { pose in
            load("wurm-" + pose.rawValue).map { (pose, $0) }
        })

    private static func load(_ name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Wurm"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The lively worm: he breathes - a barely visible rise
/// and fall from the ground -, at welcome he sways, when cheering he hops. On the
/// finished images, without a drawing in separate parts; blinking and a waving ribbon
/// would need layers of their own (later, e.g. with Rive). With "Reduce Motion" he stands still.
private struct Lively: ViewModifier {

    let pose: Worm.Pose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var jump = 0

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if pose == .cheer {
            // Cheer: two hops on appearing, then calm - endless looked nervous.
            content
                .phaseAnimator([0.0, 1.0, 0.0, 0.7, 0.0], trigger: jump) { content, p in
                    content.offset(y: -10 * p).scaleEffect(x: 1 - 0.02 * p, y: 1 + 0.04 * p, anchor: .bottom)
                } animation: { _ in
                    .easeInOut(duration: 0.22)
                }
                .onAppear { jump += 1 }
        } else {
            content.phaseAnimator([0.0, 1.0]) { content, p in
                content
                    .scaleEffect(x: 1 - 0.012 * p, y: 1 + 0.03 * p, anchor: .bottom)
                    .rotationEffect(.degrees(pose == .welcome ? -2 + 4 * p : 0), anchor: .bottom)
            } animation: { _ in
                .easeInOut(duration: 1.8)
            }
        }
    }
}

extension EmptyState where ImageContent == Worm {
    /// An empty state with the worm instead of a glyph.
    public init(
        worm title: Text, text: Text? = nil, pose: Worm.Pose = .read,
        @ViewBuilder action: () -> ActionContent
    ) {
        let button = action()
        self.init(title: title, text: text) {
            Worm(pose)
        } action: {
            button
        }
    }
}

extension EmptyState where ImageContent == Worm, ActionContent == EmptyView {
    public init(worm title: Text, text: Text? = nil, pose: Worm.Pose = .read) {
        self.init(title: title, text: text) {
            Worm(pose)
        } action: {
            EmptyView()
        }
    }
}
