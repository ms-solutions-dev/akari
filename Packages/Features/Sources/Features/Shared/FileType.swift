import UniformTypeIdentifiers

/// The file types the "On this device" source accepts, the same ones `project.yml` declares
/// as document types so that "Open in Akari" appears. The app's own `.akari` package is
/// declared as an app type (`dev.ms-solutions.akari.paket`).
enum FileType {
    static let package = UTType(exportedAs: "dev.ms-solutions.akari.paket", conformingTo: .data)
    static let cbz = UTType(importedAs: "com.akari.cbz", conformingTo: .zip)

    static var all: [UTType] {
        [package, .epub, .pdf, cbz, .zip]
    }
}
