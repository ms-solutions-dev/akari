import Library
import SourcesKit
import SwiftUI

/// Where a tap leads, as a value so that Start and Library open the same sheets
/// and a deep link can name a target later.
enum Target: Hashable {
    case title(TitleID)
    case series(SeriesID)
    /// A kind's grid, narrowed to one genre.
    case genre(Kind?, Shelf.Genre.EntryKey)
    case allGenres(Kind?)
    /// The list behind "All" for Continue reading, and for Continue listening.
    case continueReading
    case continueListening
    /// The list behind "All" for New on the shelf.
    case new
    /// The list behind "All" for stalled titles, on Start and in statistics.
    case stalled
    /// The saved list as a page with its order.
    case saved
    /// What is on the device: the page behind "All" of the downloads row.
    case device
    /// Everything by one author, the author hit in search.
    case author(String)
    /// Everything from one publisher, the publisher link in the detail.
    case publisher(String)
    /// A collection: shelf, reading list, playlist.
    case collection(CollectionID)
    case allCollections(Kind?)
}

extension View {

    /// The sheets behind the targets, once per stack, with their own namespace
    /// from which title and series zoom (``TargetStack``, `Zoom.swift`).
    func targets() -> some View {
        modifier(TargetStack())
    }
}
