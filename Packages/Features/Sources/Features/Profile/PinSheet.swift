import AccountsKit
import DesignSystem
import SwiftUI

/// The PIN sheet: four dots, a numeric keypad, a sentence on error.
///
/// Custom keys instead of a text field with a number pad: the sheet is meant for
/// switching *to* a protected profile, one thumb gesture as in streaming apps, without a system
/// keyboard rising and covering half the sheet. The check is done by the registry
/// (``ProfileRegistry/check(pin:for:)``); three wrong attempts lock for 30 seconds, and
/// the sheet visibly counts the seconds down instead of silently accepting nothing.
struct PinSheet: View {

    let profile: Profile
    /// What happens with the complete PIN: the switch, or editing.
    let action: (String) throws(ProfileError) -> Void

    @Environment(ProfileRegistry.self) private var profiles
    @Environment(\.dismiss) private var close
    @Environment(\.theme) private var theme
    @State private var input = ""
    @State private var failure: ProfileError?
    @State private var now = Date()

    /// Locked until when, from the registry, so even a freshly opened sheet knows the
    /// pause from the last attempt.
    private var lockedUntil: Date? { profiles.lockedUntil(profile) ?? locked(failure) }

    private func locked(_ failure: ProfileError?) -> Date? {
        if case .locked(let until) = failure, until > now { return until }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                ProfileImage(profile: profile, size: 56)
                    .padding(.top, 24)
                Text(verbatim: Phrase.from("pin.for", profile.name))
                    .font(Typography.title(.title3))
                points
                message
                keyboard
                    .disabled(lockedUntil != nil)
                    .opacity(lockedUntil != nil ? 0.4 : 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .paper()
            // No title in the bar: the circle with "PIN for ..." is the title, and a
            // second "PIN" above it overlapped the circle in the screenshot.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        close()
                    } label: {
                        Text(app: "action.cancel")
                    }
                }
            }
            // The seconds of the pause count down visibly, one tick per second while
            // the sheet is up.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    now = Date()
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Four dots, filled as far as typed.
    private var points: some View {
        HStack(spacing: 18) {
            ForEach(0..<PinProtection.length, id: \.self) { i in
                Circle()
                    .strokeBorder(theme.accent.color, lineWidth: 1.5)
                    .background(Circle().fill(i < input.count ? theme.accent.color : .clear))
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Phrase.from("pin.entered", input.count, PinProtection.length)))
    }

    /// The sentence under the dots: the pause with seconds, otherwise the failed attempt
    /// with what remains, otherwise nothing; a fixed height so nothing jumps.
    private var message: some View {
        Group {
            if let until = lockedUntil {
                Text(
                    verbatim: Phrase.from(
                        "pin.locked", max(1, Int(until.timeIntervalSince(now).rounded(.up))))
                )
                .foregroundStyle(ColorTheme.failure.color)
            } else if case .pinWrong(let remaining) = failure {
                Text(verbatim: Phrase.from("pin.wrong", remaining))
                    .foregroundStyle(ColorTheme.failure.color)
            } else {
                Text(verbatim: " ")
            }
        }
        .font(.footnote)
        .monospacedDigit()
        .multilineTextAlignment(.center)
    }

    private var keyboard: some View {
        let bookSeriesList: [[String]] = [
            ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"],
        ]
        return VStack(spacing: 12) {
            ForEach(bookSeriesList, id: \.self) { bookSeries in
                HStack(spacing: 12) {
                    ForEach(bookSeries, id: \.self) { pressedKey in
                        if pressedKey.isEmpty {
                            Color.clear.frame(width: 72, height: 56)
                        } else {
                            Button {
                                tap(pressedKey)
                            } label: {
                                Group {
                                    if pressedKey == "⌫" {
                                        Image(systemName: "delete.left")
                                    } else {
                                        Text(verbatim: pressedKey)
                                    }
                                }
                                .font(Typography.title(.title2, weight: .regular))
                                .monospacedDigit()
                                .frame(width: 72, height: 56)
                                .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                pressedKey == "⌫" ? Text(app: "pin.delete") : Text(verbatim: pressedKey))
                        }
                    }
                }
            }
        }
    }

    private func tap(_ pressedKey: String) {
        Haptics.selection()
        if pressedKey == "⌫" {
            if !input.isEmpty { input.removeLast() }
            return
        }
        guard input.count < PinProtection.length else { return }
        input.append(pressedKey)
        guard input.count == PinProtection.length else { return }
        do {
            try action(input)
            Haptics.success()
            close()
        } catch {
            Haptics.warning()
            failure = error
            input = ""
        }
    }
}
