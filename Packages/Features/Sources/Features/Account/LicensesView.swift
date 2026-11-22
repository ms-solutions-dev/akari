import Bedrock
import DesignSystem
import SwiftUI

/// About > Licenses: the third-party packages that ship with the app, namely Readium
/// (BSD-3), the Newsreader typeface (OFL) and what Readium brings along. Apple does not
/// require the list, the licenses themselves do (BSD-3 clause 2, OFL). Generated from
/// `Package.resolved` and the license files, never by hand.
struct LicensesView: View {

    @State private var unresolved: Licenses.Package?

    var body: some View {
        List {
            if Licenses.all.isEmpty {
                Text(app: "about.licenses.missing")
                    .foregroundStyle(ColorTheme.muted.color)
            }
            ForEach(Licenses.all, id: \.name) { package in
                Button {
                    unresolved = package
                } label: {
                    LabeledContent {
                        Text(verbatim: package.kindOrGap)
                    } label: {
                        Text(verbatim: package.name)
                        Text(verbatim: package.edition)
                            .font(.footnote)
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                }
                .foregroundStyle(ColorTheme.typography.color)
                .disabled(package.text == nil)
            }
        }
        .paper()
        .navigationTitle(Text(app: "about.licenses"))
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $unresolved) { package in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: package.place)
                            .font(.footnote)
                            .foregroundStyle(ColorTheme.muted.color)
                            .textSelection(.enabled)
                        // As text, not as an image: copyable and readable by VoiceOver.
                        Text(verbatim: package.text ?? "")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .paper()
                .navigationTitle(Text(verbatim: package.name))
                .toolbarTitleDisplayMode(.inline)
            }
            .presentationDragIndicator(.visible)
        }
    }
}

extension Licenses.Package: @retroactive Identifiable {
    public var id: String { name }
}
