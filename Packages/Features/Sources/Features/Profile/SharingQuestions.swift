import AccountsKit
import DesignSystem
import Observation
import SwiftUI

/// The questions when accepting a share:
///
/// 1. **"Adopt existing profile?"** when a local profile of the same name already exists on
///    this device (for example a family iPad that already had a profile "leser" with its own
///    reading time and saved list; the iPhone's code created a second "leser - shared"
///    beside it, and deleting the old one lost its data).
/// 2. **"What should this device be called?"** once on joining, prefilled with the system
///    name; one tap on "Continue" is enough. The name is stored as `Device` in the owner's
///    zone, where one can tell who is who.
///
/// **A state in the core that the shell shows**, like `CollectionQuestion`: the core asks
/// in `question(_:)` and waits for the answer; the stage decides who shows it. Acceptance
/// comes from three paths (QR code in the camera sheet, an `akari://` link via the shell,
/// an iCloud link at cold start), and the camera sheet is a sheet over other sheets: a
/// dialog on the shell would sit below it and never appear. So each stage registers when
/// it appears (`enters(_:)`), and **the most recently appeared one** shows the question,
/// the topmost sheet; when it closes, the next one below takes over.
///
/// **In a test** there is no stage: `decider` answers immediately.
@MainActor
@Observable
public final class SharingQuestions {

    /// What the adoption question shows: the local profile and who gives the share.
    public struct Occasion: Sendable, Hashable {
        public let local: Profile
        public let ownerName: String?
    }

    public enum Question: Sendable, Hashable {
        case adoption(Occasion)
        /// The device name, prefilled with the system name.
        case deviceName(suggestion: String)
    }

    public enum Answer: Sendable, Hashable {
        /// Bind the local profile to the share, merging reading time and saved list.
        case adopt
        /// A second profile beside it, as without a name match.
        case new
        /// Do nothing; the share is left again. For the device name: the suggestion stands.
        case cancel
        case name(String)
    }

    public private(set) var unresolved: Question?
    private var stages: [UUID] = []
    private var continuation: CheckedContinuation<Answer, Never>?
    /// Answers in place of a stage, for tests.
    public var decider: ((Question) -> Answer)?

    public init() {}

    /// Asks the question and waits until a stage (or the `decider`) answers.
    func question(_ question: Question) async -> Answer {
        if let decider { return decider(question) }
        continuation?.resume(returning: .cancel)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            unresolved = question
        }
    }

    public func answer(_ reply: Answer) {
        unresolved = nil
        continuation?.resume(returning: reply)
        continuation = nil
    }

    func enters(_ stage: UUID) {
        stages.removeAll { $0 == stage }
        stages.append(stage)
    }

    func leaves(_ stage: UUID) {
        stages.removeAll { $0 == stage }
    }

    /// Whether this stage shows the question: the most recently appeared, while it is up.
    func shows(_ stage: UUID) -> Bool { unresolved != nil && stages.last == stage }

    var adoption: Occasion? {
        if case .adoption(let fall) = unresolved { return fall }
        return nil
    }

    var deviceName: String? {
        if case .deviceName(let suggestion) = unresolved { return suggestion }
        return nil
    }
}

extension View {
    /// The dialogs "Adopt existing profile?" and "What should this device be called?", on
    /// every stage over which a share link can arrive: shell, welcome flow, account sheet,
    /// camera sheet.
    func sharingQuestions(_ questions: SharingQuestions) -> some View {
        modifier(SharingQuestionDialogs(questions: questions))
    }
}

private struct SharingQuestionDialogs: ViewModifier {

    let questions: SharingQuestions
    @State private var stage = UUID()
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .onAppear { questions.enters(stage) }
            .onDisappear { questions.leaves(stage) }
            .confirmationDialog(
                Text(verbatim: Phrase.from("profile.adopt.question", questions.adoption?.local.name ?? "")),
                isPresented: Binding(
                    get: { questions.shows(stage) && questions.adoption != nil },
                    set: { if !$0, questions.adoption != nil { questions.answer(.cancel) } }),
                titleVisibility: .visible
            ) {
                Button {
                    questions.answer(.adopt)
                } label: {
                    Text(app: "profile.adopt")
                }
                Button {
                    questions.answer(.new)
                } label: {
                    Text(app: "profile.adopt.new")
                }
                Button(role: .cancel) {
                    questions.answer(.cancel)
                } label: {
                    Text(app: "action.cancel")
                }
            } message: {
                Text(
                    verbatim: Phrase.from(
                        "profile.adopt.text", questions.adoption?.local.name ?? "",
                        questions.adoption?.ownerName ?? Phrase.from("profile.adopt.owner")))
            }
            .alert(
                Text(app: "cloud.device.name.question"),
                isPresented: Binding(
                    get: { questions.shows(stage) && questions.deviceName != nil },
                    set: { if !$0, questions.deviceName != nil { questions.answer(.cancel) } })
            ) {
                TextField(text: $name) { Text(app: "cloud.device.name") }
                Button {
                    questions.answer(.name(name))
                } label: {
                    Text(app: "action.next")
                }
            } message: {
                Text(app: "cloud.device.name.text")
            }
            .onChange(of: questions.deviceName) { _, suggestion in
                if let suggestion { name = suggestion }
            }
    }
}
