import Bedrock
import DesignSystem
import SwiftUI

/// The certificate question: computer, fingerprint, trust or not. For a **changed**
/// certificate the old fingerprint is shown next to the new one and the trust button is
/// not the prominent one; that is the case the whole mechanism was built for.
struct CertificateQuestionView: View {

    let question: CertificateQuestion.Unresolved
    let reply: (Bool) -> Void

    private var changed: Bool { question.known != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(app: changed ? "certificate.changed.text" : "certificate.text")
                }
                Section {
                    LabeledContent {
                        Text(verbatim: question.host)
                    } label: {
                        Text(app: "account.address")
                    }
                    if let known = question.known {
                        snapshot(known, title: "certificate.known")
                    }
                    snapshot(
                        question.fingerprint, title: changed ? "certificate.new" : "certificate.snapshot")
                }
                Section {
                    Button {
                        reply(true)
                    } label: {
                        Text(app: "certificate.trust")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    .tint(changed ? ColorTheme.failure.color : .accentColor)
                    Button(role: .cancel) {
                        reply(false)
                    } label: {
                        Text(app: "certificate.decline")
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .paper()
            .navigationTitle(Text(app: changed ? "certificate.changed" : "certificate.title"))
            .toolbarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func snapshot(_ snapshot: CertificateFingerprint, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(app: title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: snapshot.readable)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
