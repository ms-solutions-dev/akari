import SwiftUI

#if canImport(AVKit) && os(iOS)
    import AVKit

    /// The system's AirPlay button - HomePod, speakers, TV. An
    /// `AVRoutePickerView`, nothing custom: the sheet that opens belongs to iOS.
    struct AirPlayButton: UIViewRepresentable {
        let color: Color

        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.tintColor = UIColor(color)
            view.activeTintColor = UIColor(color)
            view.prioritizesVideoDevices = false
            return view
        }

        /// Only for a different color: every set re-tints the symbol (`tintColorDidChange`),
        /// and `updateUIView` runs on every pass of the player.
        func updateUIView(_ view: AVRoutePickerView, context: Context) {
            guard context.coordinator.color != color else { return }
            context.coordinator.color = color
            view.tintColor = UIColor(color)
            view.activeTintColor = UIColor(color)
        }

        func makeCoordinator() -> Coordinator { Coordinator(color: color) }

        final class Coordinator {
            var color: Color
            init(color: Color) { self.color = color }
        }
    }
#else
    struct AirPlayButton: View {
        let color: Color
        var body: some View { EmptyView() }
    }
#endif
