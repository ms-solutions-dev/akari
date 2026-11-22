import SwiftUI

/// The sheet: everything that comes from below - account, settings, certificate prompt,
/// volume end. A stack with the title in the middle, "Done" on the right, paper behind.
/// Whoever shows a sheet no longer writes a title style or a color.
public struct Sheet<Content: View>: View {

    private let title: Text
    private let content: Content

    public init(title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            content
                .paper()
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(app: "action.done")
                        }
                    }
                }
        }
    }
}
