import AudioPlayer
import Library
import ReadingProgress
import SourcesKit
import SwiftUI
import WidgetBridge

/// Observes what the "Continue listening" and "Reading statistics" widgets need and lets the
/// writers write, as an invisible view in the shell's background.
///
/// **Why three small views and not one `onChange` in the shell:** the listening watcher
/// reads `Player.time`, which advances twice per second. Whatever reads that value is
/// recomputed twice per second; in the shell that would be the whole tab bar, here it is an
/// empty color. The shelf watcher reads the shelf (and recomputes `continueReading` only
/// when it changes), the statistics watcher the log and the shelf's stalled titles.
/// Each schedules only when its key changes; the writer writes coalesced.
struct WidgetWatcher: View {

    let player: Player
    let inventory: LibraryService
    let reader: ReadCall
    let readingTime: ReadingTimeLog
    let profile: String
    let multipleProfiles: Bool
    let listenWriter: ContinueListeningWriter
    let statisticsWriter: ReadingStatisticsWriter
    let sources: SnapshotWriter.SourceAccess

    var body: some View {
        ZStack {
            PlayerWatcher(player: player, schedule: scheduleListen)
            ShelfWatcher(
                inventory: inventory, reader: reader, profile: profile, multipleProfiles: multipleProfiles,
                schedule: scheduleListen)
            StatisticsWatcher(
                readingTime: readingTime, inventory: inventory, profile: profile,
                multipleProfiles: multipleProfiles,
                schedule: scheduleStatistics)
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityHidden(true)
    }

    private func scheduleListen() {
        listenWriter.schedule(
            ContinueListeningWriter.Job.from(
                player, ongoing: reader.ongoing, shelf: inventory.shelf, profile: profile,
                multipleProfiles: multipleProfiles),
            sources: sources)
    }

    private func scheduleStatistics() {
        statisticsWriter.schedule(
            ReadingStatisticsWriter.Job(
                sessions: readingTime.sessions, stalled: inventory.shelf.stalled.count,
                profile: profile,
                multipleProfiles: multipleProfiles))
    }

    /// Audiobook, chapter, playing, tempo and the position in five-minute steps.
    private struct PlayerWatcher: View {
        let player: Player
        let schedule: () -> Void

        private struct EntryKey: Equatable {
            let id: String?
            let chapter: String?
            let running: Bool
            let tempo: Double
            let step: Int
        }

        private var lookupKey: EntryKey {
            EntryKey(
                id: player.audiobook?.id, chapter: player.chapter?.name, running: player.running,
                tempo: player.tempo,
                step: Int(player.time / ContinueListeningWriter.timeStep))
        }

        var body: some View {
            Color.clear.onChange(of: lookupKey, initial: true) { schedule() }
        }
    }

    /// The shelf's latest listening reading, the running title and the profile.
    private struct ShelfWatcher: View {
        let inventory: LibraryService
        let reader: ReadCall
        let profile: String
        let multipleProfiles: Bool
        let schedule: () -> Void

        private struct EntryKey: Equatable {
            let reading: Shelf.Reading?
            let ongoing: TitleID?
            let profile: String
            let multipleProfiles: Bool
        }

        private var lookupKey: EntryKey {
            EntryKey(
                reading: inventory.shelf.continueReading.first { $0.title.kind.isAudible },
                ongoing: reader.ongoing?.identifier, profile: profile, multipleProfiles: multipleProfiles)
        }

        var body: some View {
            Color.clear.onChange(of: lookupKey, initial: true) { schedule() }
        }
    }

    /// The log's sessions, the number of stalled titles and the profile.
    private struct StatisticsWatcher: View {
        let readingTime: ReadingTimeLog
        let inventory: LibraryService
        let profile: String
        let multipleProfiles: Bool
        let schedule: () -> Void

        private struct EntryKey: Equatable {
            let sessions: [ReadingSession]
            let stalled: Int
            let profile: String
            let multipleProfiles: Bool
        }

        private var lookupKey: EntryKey {
            EntryKey(
                sessions: readingTime.sessions, stalled: inventory.shelf.stalled.count,
                profile: profile,
                multipleProfiles: multipleProfiles)
        }

        var body: some View {
            Color.clear.onChange(of: lookupKey, initial: true) { schedule() }
        }
    }
}
