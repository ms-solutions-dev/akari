import DesignSystem
import SwiftUI

/// A map with its pins, rotated in quarter turns (for maps drawn
/// in landscape on an iPhone held upright).
///
/// Only the presentation rotates: the places stay stored in image coordinates 0 to 1; image
/// and pins rotate together. At 90/270 degrees the aspect ratio swaps so the rotated
/// map fills the space; the pins rotate back and stand upright, their tip still points
/// at the place. The zoom (``scale``, ``anchor``) acts on the unrotated map, so the anchor
/// is the place in the image.
struct RotatedCard: View {

    /// The map, already fitted (``CardFinder/image(_:edge:)``).
    let image: CGImage
    /// Term -> frame of the label (0 to 1, origin top left).
    let pins: [String: CGRect]
    /// Quarter turns clockwise - only counts up, so the animation always
    /// rotates forward.
    var quarter: Int = 0
    /// The zoom of the map sheet, on the unrotated map.
    var scale: CGFloat = 1
    /// The fixed point of the zoom in image coordinates.
    var anker: UnitPoint = .center
    /// Offset on screen, after the rotation - so the map follows the finger regardless of
    /// how it is rotated (``CardZoom``).
    var offset: CGSize = .zero
    var pinFont: Font = .title3.weight(.semibold)
    /// For the pin dropping in on the map sheet.
    var pinsShown = true

    private var winkel: Double { Double(quarter) * 90 }
    private var landscape: Bool { !quarter.isMultiple(of: 2) }

    var body: some View {
        let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
        GeometryReader { space in
            let frame = landscape ? CGSize(width: space.size.height, height: space.size.width) : space.size
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                ForEach(pins.keys.sorted(), id: \.self) { id in
                    if let r = pins[id] {
                        pin
                            .position(x: r.midX * frame.width, y: r.minY * frame.height)
                            .accessibilityLabel(Text(verbatim: id))
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(scale, anchor: anker)
            .rotationEffect(.degrees(winkel))
            .offset(offset)
            .frame(width: space.size.width, height: space.size.height)
        }
        .accessibilityValue(Text(verbatim: "\(quarter % 4 * 90)°"))
        .aspectRatio(landscape ? 1 / ratio : ratio, contentMode: .fit)
    }

    /// The pin stands above its place: the "upwards" offset is computed against the rotation,
    /// the mark rotates back - so it stays upright on screen.
    private var pin: some View {
        let top = pinsShown ? -12.0 : -52.0
        let rad = winkel * .pi / 180
        return Image(systemName: "mappin")
            .font(pinFont)
            .foregroundStyle(.red, .white)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .rotationEffect(.degrees(-winkel))
            .offset(x: top * sin(rad), y: top * cos(rad))
            .opacity(pinsShown ? 1 : 0)
            // Pulses twice when it drops - opacity only, calm enough even with
            // "Reduce Motion".
            .symbolEffect(.pulse, options: .repeat(2), value: pinsShown)
    }
}

/// Rotates a map by one quarter turn clockwise.
struct CardRotateButton: View {

    @Binding var quarter: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.sheet(reduceMotion)) { quarter += 1 }
        } label: {
            Image(systemName: "rotate.right")
                .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(Text(app: "card.rotate"))
    }
}

/// Zoom and offset of a map on screen - as in Photos: zooming around the
/// point between the fingers, dragging with one finger, never past the edge.
///
/// Computed as zoom around the center plus an offset on screen: a point `p` (from the
/// center) lies after the zoom at `R(s * p) + offset`, `R` the quarter turn.
struct CardZoom: Equatable {

    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let atMost: CGFloat = 4

    /// Zoom further by `factor` relative to `start`; the point `finger` (from the center)
    /// stays under the fingers.
    static func pinched(_ start: CardZoom, factor: CGFloat, finger: CGSize, size: CGSize) -> CardZoom {
        let new = min(max(start.scale * factor, 1), atMost)
        let m = new / start.scale
        let offset = CGSize(
            width: finger.width + (start.offset.width - finger.width) * m,
            height: finger.height + (start.offset.height - finger.height) * m)
        return CardZoom(scale: new, offset: limited(offset, scale: new, size: size))
    }

    /// Moved with the finger.
    static func dragged(_ start: CardZoom, around route: CGSize, size: CGSize) -> CardZoom {
        let offset = CGSize(
            width: start.offset.width + route.width, height: start.offset.height + route.height)
        return CardZoom(
            scale: start.scale, offset: limited(offset, scale: start.scale, size: size))
    }

    /// Zoom to a place (image coordinates 0 to 1) - it then sits in the center as far as the
    /// edge allows.
    static func on(_ place: CGPoint, scale: CGFloat, quarter: Int, size: CGSize) -> CardZoom {
        let landscape = !quarter.isMultiple(of: 2)
        let local = landscape ? CGSize(width: size.height, height: size.width) : size
        let p = CGSize(
            width: (place.x - 0.5) * local.width * scale, height: (place.y - 0.5) * local.height * scale
        )
        let rotated = rotated(p, quarter: quarter)
        return CardZoom(
            scale: scale,
            offset: limited(
                CGSize(width: -rotated.width, height: -rotated.height), scale: scale, size: size))
    }

    /// After a quarter turn: the offset rotates along so the same spot stays visible.
    func rotated(size: CGSize) -> CardZoom {
        CardZoom(
            scale: scale,
            offset: CardZoom.limited(
                CardZoom.rotated(offset, quarter: 1), scale: scale, size: size))
    }

    static func rotated(_ v: CGSize, quarter: Int) -> CGSize {
        switch ((quarter % 4) + 4) % 4 {
        case 1: CGSize(width: -v.height, height: v.width)
        case 2: CGSize(width: -v.width, height: -v.height)
        case 3: CGSize(width: v.height, height: -v.width)
        default: v
        }
    }

    /// The map always covers its frame completely: the offset reaches at most as far as it
    /// extends past the edge.
    static func limited(_ v: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        let rx = size.width * (scale - 1) / 2
        let ry = size.height * (scale - 1) / 2
        return CGSize(width: min(max(v.width, -rx), rx), height: min(max(v.height, -ry), ry))
    }
}
