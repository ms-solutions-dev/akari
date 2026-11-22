import Foundation

/// The sample shelf: free books that ship with the app so the empty shell has something
/// to show on first launch, and App Review has something to check.
///
/// The files live in `Beispiele/` and go through the same path as "Open in Akari" into
/// the "Device" source. There they are ordinary own books and can be removed by
/// deleting them, with no special case in the library.
enum SampleShelf {

    /// The bundled books, alphabetically; empty while the folder holds none.
    /// Read once: the contents of the app bundle do not change.
    static let files: [URL] = {
        guard let folder = Bundle.module.url(forResource: "Beispiele", withExtension: nil),
            let content = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return
            content
            .filter { ["epub", "cbz"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    /// Whether the first launch offers the "Look around first" path.
    static var present: Bool { !files.isEmpty }
}
