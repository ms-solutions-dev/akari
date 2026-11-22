import AccountsKit
import Bedrock
import CloudSync
import DesignSystem
import SourcesKit
import SwiftUI

#if canImport(CoreImage)
    import CoreImage
    import CoreImage.CIFilterBuiltins
#endif

/// "Add device": **one** QR code that carries everything the other device needs for
/// this profile: the iCloud sharing link of the zone and the accounts without
/// passwords (server addresses, user names, certificate fingerprint), in the format of the
/// setup code `akari://einrichten?...&freigabe=...&farbe=...`.
///
/// The new device scans it, with the system camera ("Open in Akari") or with
/// the app's scanner, accepts the sharing, creates the profile with name, color
/// and the owner's initial, adds the accounts and only asks for the passwords.
///
/// The link can also be shared as text (message, AirDrop), with the same content.
struct AddDeviceView: View {

    let profile: Profile

    @Environment(AppCore.self) private var core
    @Environment(ProfileRegistry.self) private var profiles
    @Environment(\.theme) private var theme
    @State private var code: SetupCode?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let code {
                    QRImage(text: code.url.absoluteString)
                        .frame(maxWidth: 280)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(Text(app: "cloud.device.qr"))
                    Text(app: "cloud.device.add.text")
                        .font(.subheadline)
                        .foregroundStyle(ColorTheme.muted.color)
                        .multilineTextAlignment(.center)
                    Text(verbatim: accountsRow(code))
                        .font(.footnote)
                        .foregroundStyle(ColorTheme.muted.color)
                        .multilineTextAlignment(.center)
                    ShareLink(item: code.url.absoluteString) {
                        Label(app: "cloud.device.link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else if let failure {
                    Label {
                        Text(verbatim: failure)
                    } icon: {
                        Image(systemName: "exclamationmark.icloud")
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                } else {
                    ProgressView().padding(40)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .paper()
        .navigationTitle(Text(app: "cloud.device.add"))
        .toolbarTitleDisplayMode(.inline)
        .task { await make() }
    }

    /// "Manga, books, audiobooks, without passwords": what the code carries.
    private func accountsRow(_ code: SetupCode) -> String {
        let names = Provider.server.filter { code.server[$0] != nil }.map {
            Phrase.from("account.kind." + $0.rawValue)
        }
        guard !names.isEmpty else { return Phrase.from("cloud.device.withoutAccounts") }
        return Phrase.from("cloud.device.accounts", names.joined(separator: ", "))
    }

    /// The zone's sharing (or the existing one), then the code from the profile's
    /// accounts: from the context if it is the active profile, otherwise from the keychain.
    private func make() async {
        var current = profiles.all.first { $0.id == profile.id } ?? profile
        // Right after launch the zone may not be bound yet. Give it one nudge
        // before the sheet says "not connected".
        if current.cloud == nil, core.context.profile.id == profile.id {
            await core.bindCloud()
            current = profiles.all.first { $0.id == profile.id } ?? profile
        }
        guard let zone = current.cloud else {
            failure = Phrase.from("cloud.state.unbound")
            return
        }
        do throws(CloudError) {
            let sharing = try await core.cloud.share(zone, title: profile.name)
            guard let url = sharing.url else {
                failure = Phrase.from("cloud.state.unreachable")
                return
            }
            if core.context.profile.id == profile.id {
                code = core.context.accounts.setupCode(
                    person: profile.name, color: profile.color, sharing: url)
            } else {
                let store = SecureStore()
                code = SetupCode.from(
                    accounts: AccountStore(store: store, profile: profiles.persistence(profile)).all(),
                    trusts: CertificateTrustStore(store: store), person: profile.name, color: profile.color,
                    sharing: url)
            }
        } catch {
            failure = CloudRow.reason(error)
        }
    }
}

/// A QR code from CoreImage: black on white, without smoothing, so that the other
/// device's camera also reads it from the screen.
struct QRImage: View {

    let text: String

    var body: some View {
        if let image = QRImage.draw(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    static func draw(_ text: String) -> CGImage? {
        #if canImport(CoreImage)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else { return nil }
            let enlarged = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            return CIContext().createCGImage(enlarged, from: enlarged.extent)
        #else
            return nil
        #endif
    }
}
