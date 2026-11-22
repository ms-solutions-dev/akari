import SwiftUI

#if os(iOS)
    import UIKit

    /// A spread with pinch and double tap - a `UIScrollView`, because SwiftUI has no
    /// zoom that anchors at the tap point and hands control back to the outer
    /// scroller when dragging at the edge.
    ///
    /// **One stage, one or two sheets:** the pages lie side by side on a
    /// stage that zooms as a whole - otherwise in the double spread only the half
    /// the finger was on zooms. The sheets touch at the fold like
    /// in a book, and the stage sits in the middle.
    ///
    /// At zoom 1 the inner scroller holds no finger - paging and dragging
    /// down go to SwiftUI; zoomed in it holds, and only at the edge does
    /// paging continue. The single tap waits for the double tap to fail - only so
    /// is a double tap not paging plus zoom.
    struct ZoomImage: UIViewRepresentable {

        /// The sheets from left to right; `nil` is a sheet still coming - it
        /// keeps its place at aspect ratio 2:3.
        let images: [CGImage?]
        /// The spread is the shown one - if not, the zoom resets to 1
        /// (reset when paging).
        let current: Bool
        /// A single tap with its x position on the whole screen.
        let tip: (CGFloat) -> Void

        func makeUIView(context: Context) -> UIScrollView {
            let roller = PageScroller()
            roller.delegate = context.coordinator
            roller.minimumZoomScale = 1
            roller.maximumZoomScale = 4
            roller.showsHorizontalScrollIndicator = false
            roller.showsVerticalScrollIndicator = false
            roller.bouncesZoom = true
            roller.contentInsetAdjustmentBehavior = .never
            roller.backgroundColor = .black
            roller.isScrollEnabled = false
            let stage = UIView()
            roller.addSubview(stage)
            roller.stage = stage
            roller.create(images)
            context.coordinator.roller = roller
            let double = UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
            double.numberOfTapsRequired = 2
            let single = UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
            single.require(toFail: double)
            roller.addGestureRecognizer(double)
            roller.addGestureRecognizer(single)
            return roller
        }

        func updateUIView(_ roller: UIScrollView, context: Context) {
            context.coordinator.tip = tip
            guard let pageScroller = roller as? PageScroller else { return }
            // One page becomes two (rotating with the same identifier): then new
            // frames, otherwise the second sheet stayed invisible.
            if pageScroller.imageViews.count != images.count {
                roller.setZoomScale(1, animated: false)
                pageScroller.create(images)
            } else {
                var changed = false
                for (hostView, image) in zip(pageScroller.imageViews, images)
                where hostView.image?.cgImage !== image {
                    hostView.image = image.map { UIImage(cgImage: $0) }
                    changed = true
                }
                if changed { pageScroller.setNeedsLayout() }
            }
            if !current, roller.zoomScale != 1 { roller.setZoomScale(1, animated: false) }
        }

        func makeCoordinator() -> Coordinator { Coordinator(tip: tip) }

        /// Lays the sheets side by side fitted at zoom 1 - on first layout,
        /// on rotation, after zooming back out; zoomed in, everything stays as it is.
        final class PageScroller: UIScrollView {
            var stage: UIView?
            var imageViews: [UIImageView] = []

            /// One frame per sheet, the old ones removed.
            func create(_ images: [CGImage?]) {
                guard let stage else { return }
                imageViews.forEach { $0.removeFromSuperview() }
                imageViews = images.map { image in
                    let hostView = UIImageView(image: image.map { UIImage(cgImage: $0) })
                    hostView.contentMode = .scaleAspectFit
                    hostView.isAccessibilityElement = false
                    stage.addSubview(hostView)
                    return hostView
                }
                setNeedsLayout()
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                guard zoomScale == 1, let stage, !imageViews.isEmpty, bounds.width > 0 else { return }
                let cell = CGSize(width: bounds.width / CGFloat(imageViews.count), height: bounds.height)
                let sizes = imageViews.map { hostView -> CGSize in
                    let measures = hostView.image?.size ?? CGSize(width: 2, height: 3)
                    let factor = min(cell.width / measures.width, cell.height / measures.height)
                    return CGSize(width: measures.width * factor, height: measures.height * factor)
                }
                let width = sizes.reduce(0) { $0 + $1.width }
                let height = sizes.map(\.height).max() ?? 0
                let target = CGRect(
                    x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width,
                    height: height)
                var x: CGFloat = 0
                var frame: [CGRect] = []
                for size in sizes {
                    frame.append(
                        CGRect(
                            x: x, y: (height - size.height) / 2, width: size.width,
                            height: size.height))
                    x += size.width
                }
                guard stage.frame != target || zip(imageViews, frame).contains(where: { $0.frame != $1 })
                else {
                    return
                }
                stage.frame = target
                for (hostView, r) in zip(imageViews, frame) { hostView.frame = r }
                contentSize = bounds.size
            }
        }

        final class Coordinator: NSObject, UIScrollViewDelegate {
            weak var roller: PageScroller?
            var tip: (CGFloat) -> Void

            init(tip: @escaping (CGFloat) -> Void) { self.tip = tip }

            func viewForZooming(in scrollView: UIScrollView) -> UIView? { roller?.stage }

            /// The stage stays centered when it is smaller than the scroller -
            /// otherwise a zoomed-in spread sticks to the top left.
            func scrollViewDidZoom(_ roller: UIScrollView) {
                roller.isScrollEnabled = roller.zoomScale > 1.01
                guard let stage = self.roller?.stage else { return }
                let dx = max(0, (roller.bounds.width - roller.contentSize.width) / 2)
                let dy = max(0, (roller.bounds.height - roller.contentSize.height) / 2)
                stage.center = CGPoint(
                    x: roller.contentSize.width / 2 + dx, y: roller.contentSize.height / 2 + dy)
            }

            /// Back to 1: the stage returns to its place.
            func scrollViewDidEndZooming(_ roller: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
                if scale <= 1.01 { roller.setNeedsLayout() }
            }

            @objc func singleTap(_ geste: UITapGestureRecognizer) {
                guard let roller = geste.view as? UIScrollView else { return }
                // The zone applies to the whole screen, not half the double spread.
                tip(geste.location(in: roller.window).x)
            }

            /// Double tap: at the spot to two and a half times, or back to fit.
            @objc func doubleTap(_ geste: UITapGestureRecognizer) {
                guard let roller = geste.view as? UIScrollView, let stage = self.roller?.stage else {
                    return
                }
                if roller.zoomScale > 1.01 {
                    roller.setZoomScale(1, animated: true)
                    return
                }
                let target: CGFloat = 2.5
                let point = geste.location(in: stage)
                let width = roller.bounds.width / target
                let height = roller.bounds.height / target
                roller.zoom(
                    to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                    animated: true)
            }
        }
    }
#else
    /// On the Mac (`swift test` only): the sheets side by side, without zoom.
    struct ZoomImage: View {
        let images: [CGImage?]
        let current: Bool
        let tip: (CGFloat) -> Void

        var body: some View {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                        } else {
                            Color.black
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture { place in tip(place.x + geo.frame(in: .global).minX) }
            }
        }
    }
#endif
