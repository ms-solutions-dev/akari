import Bedrock
import Foundation
import SourcesKit

/// The move from "one sign-in per device" to "profile 1" — once, on the first
/// launch with profiles.
///
/// **Move, don't copy:** What lay under `konto.komga`, `gemerkt`, `app.theme` or
/// `Application Support/fortschritt` ends up under `profil.1.konto.komga`, in the
/// suite of profile 1 and under `Application Support/profile/1/fortschritt` — and
/// the old location is empty. A copy would mean two truths, and the older one would
/// win on the next error.
///
/// **The plan comes from above:** This package does not know the keys of the saved
/// list, the theme choice or the start row by name — `Features` says what moves along
/// (``Plan``), here is only how. The accounts and their lists the package knows
/// itself; those always come along.
///
/// **Nothing is lost when something is missing:** A key that is not there is
/// skipped; so is a folder that is not there. A device without account and without
/// saved list gets an empty profile 1 — the same path, no special case.
public struct ProfileMigration: Sendable {

    /// Where something in the profile folder goes.
    public enum Target: Sendable, Hashable {
        case inventory, progress, states, readingTime

        func url(in persistence: ProfileStore) -> URL {
            switch self {
            case .inventory: persistence.inventory
            case .progress: persistence.progress
            case .states: persistence.states
            case .readingTime: persistence.readingTime
            }
        }
    }

    /// A move of files.
    public enum Move: Sendable, Hashable {
        /// A folder or a file moves as a whole to the target.
        case whole(old: URL, to: Target)
        /// The files of a folder whose name starts like this move into the target folder —
        /// the old reading-state files lay loose under "Application Support".
        case files(in: URL, startingWith: [String], to: Target)
    }

    /// What moves along besides the accounts.
    public struct Plan: Sendable, Hashable {
        /// UserDefaults keys that move from the standard defaults into the profile's suite.
        public var settings: [String]
        public var moves: [Move]

        public init(settings: [String] = [], moves: [Move] = []) {
            self.settings = settings
            self.moves = moves
        }
    }

    public let plan: Plan

    public init(plan: Plan) {
        self.plan = plan
    }

    /// Whether anything lies in the old layout — one account is enough.
    public static func legacyLayoutPresent(store: any KeyValueStore) -> Bool {
        !AccountStore(store: store).all().isEmpty
    }

    /// Runs the move. Returns which accounts moved along — the name of profile 1 is
    /// derived from them.
    @discardableResult
    public func execute(
        store: any KeyValueStore, from settings: UserDefaults, to persistence: ProfileStore
    ) -> [AccountSlot: AccountEntry] {
        let accounts = accounts(store: store, to: persistence)
        for lookupKey in plan.settings {
            guard let value = settings.object(forKey: lookupKey) else { continue }
            persistence.settings.set(value, forKey: lookupKey)
            settings.removeObject(forKey: lookupKey)
        }
        for move in plan.moves { execute(move, to: persistence) }
        return accounts
    }

    /// The accounts: every occupied key raw from old to new; the lists of the multi-slot
    /// providers are rebuilt on adoption.
    private func accounts(
        store: any KeyValueStore, to persistence: ProfileStore
    ) -> [AccountSlot: AccountEntry] {
        let legacy = AccountStore(store: store)
        let new = AccountStore(store: store, profile: persistence)
        let entries = legacy.all()
        for provider in Provider.server {
            for slot in legacy.slots(provider) {
                guard let raw = legacy.raw(slot) else { continue }
                try? new.adopt(raw: raw, on: slot)
            }
        }
        for lookupKey in legacy.usedKeys() { try? store.remove(lookupKey) }
        return entries
    }

    private func execute(_ move: Move, to persistence: ProfileStore) {
        let fm = FileManager.default
        switch move {
        case .whole(let legacy, let target):
            guard fm.fileExists(atPath: legacy.path) else { return }
            let new = target.url(in: persistence)
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: new) }
            try? fm.moveItem(at: legacy, to: new)
        case .files(let folder, let prefixes, let target):
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
            let targetFolder = target.url(in: persistence)
            for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
                try? fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                let new = targetFolder.appending(path: name)
                if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: new) }
                try? fm.moveItem(at: folder.appending(path: name), to: new)
            }
        }
    }
}
