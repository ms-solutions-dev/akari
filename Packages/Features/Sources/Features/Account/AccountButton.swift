import AccountsKit
import DesignSystem
import SwiftUI

/// The button at the top right, the same on each of the three tabs. It shows the
/// profile (``ProfileCircle``); the name stays so that Start, Library and Search can
/// keep calling it as before.
///
/// `.primaryAction` instead of `.topBarTrailing`: same result on iOS, and the package
/// still builds on the Mac, where `topBarTrailing` does not exist and `swift test` runs.
struct AccountButton: ToolbarContent {

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            AccountCircle()
        }
    }
}

/// The circle itself, as a view so that Start can place it in its header next to the
/// brand mark. It is the profile circle.
typealias AccountCircle = ProfileCircle
