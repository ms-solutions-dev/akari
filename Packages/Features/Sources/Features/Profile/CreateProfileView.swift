import AccountsKit
import CloudSync
import DesignSystem
import SwiftUI

/// Create a profile or edit one: name, color, "For a child" with maximum
/// age, PIN. One form for both, so that "Manage" does not get a second face.
///
/// **The color is a theme:** the circle carries the accent of one of the four themes,
/// not a free color, so every circle fits every paper and the picker
/// is the same as in appearance. The profile chooses the interface theme itself
/// later; here it is only about the circle.
///
/// **"For a child"** means: the shelf filters by age rating (6/12/16), import,
/// sharing, sign-out and Wikipedia are off. When creating a child profile
/// and an adult profile has no PIN, the sheet says so, since a barrier
/// that a tap on the other circle bypasses is none.
///
/// **The PIN** is typed twice so that a typo does not lock the profile; it
/// leaves the sheet only as salt and hash (``PinProtection``).
///
/// **The form of an existing profile** leads to "iCloud & Devices"
/// (``ProfileCloudView``), and a new profile carries the hint: whoever already reads on
/// another device fetches the profile from there by QR code instead of creating it
/// here anew. Removing cleans up the zone as well (``AppCore/removeProfile(_:)``).
struct CreateProfileView: View {
    /// "Reduce Motion": then no animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The profile being edited; `nil` means a new one.
    var existing: Profile? = nil

    @Environment(ProfileRegistry.self) private var profiles
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var back
    @State private var scanner = false
    @State private var name = ""
    @State private var color: ColorTheme = .preset
    @State private var kind = false
    @State private var maxAge = Profile.ageLevels[1]
    @State private var withPin = false
    @State private var pin = ""
    @State private var pinRepeated = ""
    @State private var changePin = false
    @State private var failure: ProfileError?
    @State private var pinHint: [Profile] = []
    @State private var removeQuestion = false
    @State private var loaded = false
    @State private var cloudFailure: String?

    private var new: Bool { existing == nil }

    /// Whether the PIN fields count: with a new profile when the switch is on, with an
    /// existing one only if "Change PIN" is open or there was none yet.
    private var pinFieldsActive: Bool {
        withPin && (new || changePin || existing?.protected == false)
    }

    private var pinValid: Bool {
        !pinFieldsActive || (PinProtection.valid(pin) && pin == pinRepeated)
    }

    private var savable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pinValid
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ProfileImage(
                        profile: Profile(id: 0, name: name, color: color.rawValue), size: 56)
                    TextField(text: $name, prompt: Text(app: "profile.name.placeholder")) {
                        Text(app: "profile.name")
                    }
                    .submitLabel(.done)
                }
                ColorSwatchPicker(chosen: color) { color = $0 }
            }

            if new {
                Section {
                    Button {
                        scanner = true
                    } label: {
                        Label(app: "profile.fromDevice", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text(app: "profile.fromDevice.text")
                }
            }

            Section {
                Toggle(isOn: $kind.animation()) {
                    Text(app: "profile.kind")
                }
                if kind {
                    Picker(selection: $maxAge) {
                        ForEach(Profile.ageLevels, id: \.self) { age in
                            Text(verbatim: Phrase.from("profile.age.level", age)).tag(age)
                        }
                    } label: {
                        Text(app: "profile.age")
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                Text(app: kind ? "profile.kind.text" : "profile.kind.hint")
            }

            Section {
                Toggle(isOn: $withPin.animation()) {
                    Text(app: "profile.pin")
                }
                if withPin, !new, existing?.protected == true, !changePin {
                    Button {
                        withAnimation(Motion.soft(reduceMotion)) { changePin = true }
                    } label: {
                        Text(app: "profile.pin.change")
                    }
                }
                if pinFieldsActive {
                    PinField(title: "profile.pin.new", value: $pin)
                    PinField(title: "profile.pin.repeat", value: $pinRepeated)
                }
            } footer: {
                if pinFieldsActive, !pin.isEmpty || !pinRepeated.isEmpty, !pinValid {
                    Text(app: PinProtection.valid(pin) ? "profile.pin.unequal" : "profile.pin.fourDigits")
                        .foregroundStyle(ColorTheme.failure.color)
                } else {
                    Text(app: "profile.pin.text")
                }
            }

            if let existing {
                Section {
                    NavigationLink(value: AccountTarget.profileCloud(existing)) {
                        Label(app: "cloud.title", systemImage: "icloud")
                    }
                } footer: {
                    Text(app: existing.shared ? "cloud.shared.short" : "cloud.short")
                }
            }

            if let existing, profiles.all.count > 1 {
                Section {
                    Button(role: .destructive) {
                        removeQuestion = true
                    } label: {
                        Label(app: "profile.remove", systemImage: "trash")
                    }
                } footer: {
                    Text(verbatim: Phrase.from("profile.remove.text", existing.name))
                }
            }
        }
        .sheet(isPresented: $scanner) {
            CodeScannerView()
        }
        .paper()
        .navigationTitle(new ? Text(app: "profile.new") : Text(verbatim: existing?.name ?? ""))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: persist) {
                    Text(app: new ? "profile.create" : "action.done")
                }
                .disabled(!savable)
            }
        }
        .onAppear(perform: load)
        .alert(
            Text(app: "profile.pinHint.title"),
            isPresented: Binding(get: { !pinHint.isEmpty }, set: { if !$0 { pinHint = [] } })
        ) {
            Button {
                pinHint = []
                back()
            } label: {
                Text(app: "action.ok")
            }
        } message: {
            Text(
                verbatim: Phrase.from(
                    "profile.pinHint.text", pinHint.map(\.name).joined(separator: ", ")))
        }
        .alert(
            Text(app: "profile.error"),
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button {
                failure = nil
            } label: {
                Text(app: "action.ok")
            }
        }
        .alert(
            Text(app: "profile.error"),
            isPresented: Binding(get: { cloudFailure != nil }, set: { if !$0 { cloudFailure = nil } })
        ) {
            Button {
                cloudFailure = nil
            } label: {
                Text(app: "action.ok")
            }
        } message: {
            Text(verbatim: cloudFailure ?? "")
        }
        .confirmationDialog(
            Text(app: "profile.remove.question"), isPresented: $removeQuestion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard let existing else { return }
                Task {
                    do throws(CloudError) {
                        try await core.removeProfile(existing)
                        Haptics.success()
                        back()
                    } catch {
                        cloudFailure = CloudRow.reason(error)
                    }
                }
            } label: {
                Text(app: "profile.remove")
            }
        } message: {
            Text(app: "profile.remove.text.short")
        }
    }

    /// Load an existing profile into the form, once, not on every appearance.
    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }
        name = existing.name
        color = existing.theme
        kind = existing.kind
        maxAge = existing.maxAge ?? Profile.ageLevels[1]
        withPin = existing.protected
    }

    private func persist() {
        let age = kind ? maxAge : nil
        do throws(ProfileError) {
            if let existing {
                var changed = existing
                changed.name = name
                changed.color = color.rawValue
                changed.maxAge = age
                profiles.change(changed)
                // Name and color into the zone, for the other device's zone choice and
                // the profile a participant creates.
                Task { await core.bindCloud() }
                if pinFieldsActive {
                    try profiles.setPin(pin, for: changed)
                } else if !withPin, existing.protected {
                    try profiles.setPin(nil, for: changed)
                }
            } else {
                try profiles.create(
                    to: name, color: color.rawValue, maxAge: age, pin: withPin ? pin : nil)
            }
            Haptics.success()
            // A new child profile: adults without a PIN get the hint
            // before the sheet closes.
            let withoutPin = profiles.adultsWithoutPin
            if age != nil, !withoutPin.isEmpty, existing?.kind != true {
                pinHint = withoutPin
            } else {
                back()
            }
        } catch {
            failure = error
        }
    }
}

/// A field for four digits: obscured, number pad, accepts no more than four.
private struct PinField: View {
    let title: LocalizedStringKey
    @Binding var value: String

    var body: some View {
        SecureField(text: $value, prompt: Text(verbatim: "••••")) {
            Text(app: title)
        }
        #if os(iOS)
            .keyboardType(.numberPad)
        #endif
        .onChange(of: value) { _, new in
            let digits = String(new.filter(\.isNumber).prefix(PinProtection.length))
            if digits != new { value = digits }
        }
    }
}

/// The four accent colors as circles: the same picker as appearance, only
/// without paper; this is about the circle, not the page.
struct ColorSwatchPicker: View {

    let chosen: ColorTheme
    let choose: (ColorTheme) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(app: "profile.color")
            Spacer()
            ForEach(ColorTheme.allCases) { theme in
                Button {
                    Haptics.selection()
                    choose(theme)
                } label: {
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if chosen == theme {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(theme.buttonText.color)
                            }
                        }
                        .frame(minWidth: TapTarget.atLeast, minHeight: TapTarget.atLeast)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(appKey: theme.lookupKey))
                .accessibilityAddTraits(chosen == theme ? [.isSelected] : [])
            }
        }
    }
}
