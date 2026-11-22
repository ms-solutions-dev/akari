import CloudSync
import Foundation
import Observation

/// Where the theme choice lives: in the profile's UserDefaults, and as a
/// record `Profileinstellung/theme` in the profile zone (before that the
/// iCloud key-value store per profile name), so iPhone and iPad show the same.
///
/// **Both, not one:** the zone only fills after the first trip to the
/// server; whoever reads only it shows the default briefly and then jumps. The
/// mirror holds the last known value, the zone brings the newer one - and
/// reports it via the observation, after which `chosen` follows. With two changes
/// the younger one wins.
@MainActor
@Observable
public final class ThemeChoice {

    public static let storeKey = "app.theme"
    /// The record name in the zone (type `Profileinstellung`, field `wert`).
    public static let recordName = "theme"

    public private(set) var chosen: ColorTheme

    private let persistence: UserDefaults
    private let cloud: ProfileZone?
    private var observation: ObservationToken?

    /// A profile's old iCloud key (`profil.<name>.theme`) - only
    /// for the transition.
    public static func cloudKey(profile name: String) -> String { "profil.\(name).theme" }

    /// - Parameters:
    ///   - persistence: the profile's UserDefaults
    ///   - cloud: the profile's zone; `nil` in tests and previews - there is no iCloud there
    ///   - legacyData: the old key in the iCloud key-value store, to be collected once
    public init(
        persistence: UserDefaults = .standard, cloud: ProfileZone? = nil, legacyData: LegacyData? = nil
    ) {
        self.persistence = persistence
        self.cloud = cloud
        let value = persistence.string(forKey: ThemeChoice.storeKey)
        self.chosen = value.flatMap(ColorTheme.init(rawValue:)) ?? .preset
        guard let cloud else { return }
        if let legacyData {
            if let old = legacyData.text().flatMap(ColorTheme.init(rawValue:)),
                cloud.record(type: CloudHub.settingType, name: ThemeChoice.recordName) == nil
            {
                set(old)
            }
            legacyData.remove()
        }
        if let there = ThemeChoice.theme(from: cloud.allRecords(ofType: CloudHub.settingType)) {
            adopt(there)
        } else if value != nil {
            writeCloud(chosen)
        }
        observation = cloud.observe(CloudHub.settingType) { [weak self] records in
            if let theme = ThemeChoice.theme(from: records) { self?.adopt(theme) }
        }
    }

    public func set(_ theme: ColorTheme) {
        chosen = theme
        persistence.set(theme.rawValue, forKey: ThemeChoice.storeKey)
        writeCloud(theme)
    }

    private func writeCloud(_ theme: ColorTheme) {
        guard let cloud,
            cloud.record(type: CloudHub.settingType, name: ThemeChoice.recordName)?[
                CloudHub.valueField]?.text != theme.rawValue
        else { return }
        cloud.write(
            CloudRecord(
                type: CloudHub.settingType, name: ThemeChoice.recordName,
                fields: [CloudHub.valueField: .text(theme.rawValue)]))
    }

    private func adopt(_ theme: ColorTheme) {
        guard theme != chosen else { return }
        chosen = theme
        persistence.set(theme.rawValue, forKey: ThemeChoice.storeKey)
    }

    static func theme(from records: [CloudRecord]) -> ColorTheme? {
        records.first { $0.name == recordName }?[CloudHub.valueField]?.text.flatMap(
            ColorTheme.init(rawValue:))
    }
}
