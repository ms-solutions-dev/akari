import Foundation
import SourcesKit

/// The rules for keeping an audiobook as pure functions — testable without server
/// and without disk.
///
/// An audiobook is not a file but an ``AudioManifest``: up to a hundred tracks with
/// location and duration, plus the chapters. On the device every track lies as its
/// own file in track order (`spur-0001.mp3`), the manifest next to them as
/// `tonband.json` — so the player knows chapters and locations even when the server
/// does not answer, and the files stay individually resumable.
public enum AudiobookStock {

    /// The name of the saved manifest in the title's folder.
    public static let volumeFile = "tonband.json"

    /// The file names of the tracks, in track order — numbered with four digits, with
    /// the extension the server names (AVPlayer recognizes a file by its name),
    /// otherwise the one from the address.
    public static func filenames(_ volume: AudioManifest) -> [String] {
        volume.tracks.enumerated().map { i, track in
            let fileExtension = track.fileExtension ?? track.address.pathExtension
            return String(format: "spur-%04d", i + 1) + (fileExtension.isEmpty ? "" : "." + fileExtension)
        }
    }

    /// The progress as a fraction: by bytes when the size is known (up to 0.99 — only
    /// completion reports done), otherwise by finished tracks.
    public static func fraction(bytes: Int64, total: Int64?, track: Int, from count: Int) -> Double {
        if let total, total > 0 { return min(Double(bytes) / Double(total), 0.99) }
        return min(Double(track) / Double(max(count, 1)), 0.99)
    }

    /// The manifest with the files on the device instead of the addresses on the
    /// server — `nil` if the count does not match (a manifest from yesterday, files from today).
    public static func local(_ volume: AudioManifest, files: [URL]) -> AudioManifest? {
        guard files.count == volume.tracks.count, !files.isEmpty else { return nil }
        return AudioManifest(
            tracks: zip(volume.tracks, files).map { track, file in track.with(address: file) },
            chapter: volume.chapter, duration: volume.duration)
    }
}

extension KeepStore {

    /// A title's saved manifest — as the server named it, with its addresses.
    public func audioManifest(_ identifier: TitleID) -> AudioManifest? {
        guard
            let data = try? Data(
                contentsOf: folder(for: identifier).appending(path: AudiobookStock.volumeFile))
        else { return nil }
        return try? JSONDecoder().decode(AudioManifest.self, from: data)
    }
}
