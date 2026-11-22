import AccountsKit
import DesignSystem
import SwiftUI

/// The profile circle at the top right, the same on every tab: the reader's initial in the
/// color of their profile. It replaces the account circle, which took the initial from the
/// first account.
///
/// Carries the red dot while an account has expired, and only then: a server that is
/// merely not answering is no task for the user; the banner in the area says so. A tap
/// opens "Who is reading?" with the accounts below (`AccountsView`).
///
/// The sheet hangs here, inside the shell's environment chain; outside it crashes on
/// opening because it reads the registry and library from the environment.
struct ProfileCircle: View {

    @Environment(AccountRegistry.self) private var accounts
    @Environment(\.profile) private var profile
    @State private var unresolved = false

    var body: some View {
        Button {
            unresolved = true
        } label: {
            ProfileImage(profile: profile, size: 28)
                .overlay(alignment: .topTrailing) {
                    if accounts.needsAttention {
                        Circle().fill(ColorTheme.failure.color).frame(width: 8, height: 8).offset(x: 1, y: -1)
                    }
                }
                .accessibilityLabel(Text(verbatim: profile.name))
        }
        .accessibilityHint(
            accounts.needsAttention
                ? Text(app: "account.status.expired") : Text(app: "profile.switch")
        )
        .sheet(isPresented: $unresolved) {
            AccountsView()
        }
        // `AKARI_PROBE=konto|statistik|statistik-titel|statistik-einzeln|profil|
        // profilanlegen|pin|wolke|geraet-hinzufuegen` opens the sheet for a screenshot;
        // what appears in it is up to the sheet.
        .onAppear {
            if ProfileCircle.samples.contains(ProcessInfo.processInfo.environment["AKARI_PROBE"] ?? "") {
                unresolved = true
            }
        }
    }

    static let samples = [
        "konto", "statistik", "statistik-titel", "statistik-einzeln", "profil", "profilanlegen", "pin",
        "wolke",
        "geraet-hinzufuegen",
    ]
}

/// The circle with initial, the same at every size: 28 pt in the bar, 56 pt in "Who is
/// reading?". The color is the accent of the theme the profile chose; a child profile has
/// nothing special about it, the name says it.
struct ProfileImage: View {

    let profile: Profile
    var size: CGFloat = 28

    var body: some View {
        Text(verbatim: profile.initial)
            .font(size > 40 ? Typography.title(.title2, weight: .semibold) : Typography.name(.footnote))
            .fontWeight(.semibold)
            .foregroundStyle(profile.theme.buttonText.color)
            .frame(width: size, height: size)
            .background(profile.theme.accent.color, in: Circle())
            .accessibilityHidden(true)
    }
}
