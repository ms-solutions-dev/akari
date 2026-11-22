import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// Storing reading states on their own: a new state used to rewrite
/// the whole Grimmory extract — 25 MB of JSON including the core — and the core was rebuilt
/// at every launch because of a percent-encoded path.
@Suite("Store: states and core")
struct StoreStatesTests {

    /// With a space in the folder — like "Application Support" on the device; without it the
    /// path error would stay invisible.
    private func persistence() -> LibraryStore {
        LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(
                path: "ablage mit raum-\(UUID().uuidString)"))
    }

    private let source = SourceID(provider: .grimmory, server: "buecher.example")

    /// Large enough for a core.
    private func largeExtract(states: [TitleID: ReadingState] = [:]) -> LibraryExtract {
        let title = (0...LibraryStore.kernAb).map { n in
            Title(
                identifier: TitleID(source: source, id: "\(n)"), kind: .book, name: "T \(n)",
                added: MockShelf.state.addingTimeInterval(TimeInterval(-n * 60)))
        }
        return LibraryExtract(source: source, title: title, readingStates: states, state: MockShelf.state)
    }

    private func date(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate]
            as? Date
    }

    private func files(_ persistence: LibraryStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: persistence.folder.path(percentEncoded: false)))
            ?? []).sorted()
    }

    @Test("A state writes only the states file; extract and core read it along")
    func stateWithoutExtract() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let writer = StoreWriter(persistence: persistence, quiet: .milliseconds(1))
        let old = largeExtract()
        await writer.write(old)
        let extractFile = persistence.folder.appending(path: "grimmory@buecher.example.json")
        let previously = try #require(date(extractFile))

        // A title among the 200 youngest — it is already in the core.
        let identifier = TitleID(source: source, id: "5")
        let state = ReadingState(position: .fraction(0.4), timestamp: Date())
        await writer.schedule(largeExtract(states: [identifier: state]), statesOnly: true)
        await writer.secure()

        #expect(date(extractFile) == previously)
        #expect(files(persistence).contains("grimmory@buecher.example.staende.json"))
        #expect(persistence.loadExtract(source)?.readingStates[identifier]?.position == state.position)
        #expect(persistence.readCore(source)?.readingStates[identifier]?.position == state.position)
    }

    @Test("A state outside the core rewrites the core — otherwise it would be missing in continue reading")
    func stateOutsideCore() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let writer = StoreWriter(persistence: persistence, quiet: .milliseconds(1))
        await writer.write(largeExtract())
        // The oldest title: not among the 200 youngest, hence not in the core.
        let old = TitleID(source: source, id: "\(LibraryStore.kernAb)")
        #expect(persistence.readCore(source)?.title.contains { $0.identifier == old } == false)

        await writer.writeStates(
            largeExtract(states: [old: ReadingState(position: .fraction(0.1), timestamp: Date())]))
        #expect(persistence.readCore(source)?.title.contains { $0.identifier == old } == true)
    }

    @Test("The whole extract replaces the states file")
    func fullExtractReplaces() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let writer = StoreWriter(persistence: persistence, quiet: .milliseconds(1))
        let identifier = TitleID(source: source, id: "5")
        await writer.writeStates(
            largeExtract(states: [identifier: ReadingState(position: .fraction(0.4), timestamp: Date())]))
        // Afterwards the server delivers an extract without the state (reset).
        await writer.write(largeExtract())
        #expect(!files(persistence).contains("grimmory@buecher.example.staende.json"))
        #expect(persistence.loadExtract(source)?.readingStates[identifier] == nil)
    }

    @Test("An existing core is not rewritten on every launch")
    func coreOnlyIfMissing() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        persistence.writeCore(largeExtract())
        #expect(persistence.writeCoreIfMissing(largeExtract()) == nil)
    }

    @Test("If a scheduled write changes more than states, the bundle writes the whole extract")
    func mixedSchedule() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let writer = StoreWriter(persistence: persistence, quiet: .seconds(60))
        await writer.schedule(largeExtract(), statesOnly: false)
        await writer.schedule(largeExtract(), statesOnly: true)
        await writer.secure()
        #expect(files(persistence).contains("grimmory@buecher.example.json"))
    }
}
