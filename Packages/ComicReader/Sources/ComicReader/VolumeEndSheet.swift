import DesignSystem
import SwiftUI

/// The sheet after the last page: "Volume finished", the next volume as
/// primary button, plus "To the series" and "Close" - like the TV app toward the
/// next part. Never a review prompt.
struct VolumeEndSheet: View {

    let volume: Reader
    let next: Reader?
    let toSeries: (() -> Void)?
    let proceed: (Reader) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                Text(app: "reader.volumeEnd")
                    .font(Typography.title(.title2))
                    .foregroundStyle(.white)
                Text(verbatim: [volume.name, volume.subline].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                if let next {
                    Button {
                        proceed(next)
                    } label: {
                        VStack(spacing: 2) {
                            Text(app: "reader.continueReading")
                            Text(verbatim: next.subline ?? next.name)
                                .font(.caption)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: 320)
                    }
                    .buttonStyle(.primary)
                }
                if let toSeries {
                    Button {
                        dismiss()
                        toSeries()
                    } label: {
                        Text(app: "reader.toSeries")
                            .frame(maxWidth: 320)
                            .frame(minHeight: TapTarget.atLeast)
                    }
                    .foregroundStyle(.white)
                }
                Button {
                    dismiss()
                } label: {
                    Text(app: "action.close")
                        .frame(maxWidth: 320)
                        .frame(minHeight: TapTarget.atLeast)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
