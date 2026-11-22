import SwiftUI
import WidgetKit

/// The entry of the widget extension - one bundle, three widgets: "Continue reading",
/// "Continue listening" and "Reading statistics".
///
/// The extension pulls **one** package (`WidgetBridge`, Foundation only) and nothing else
/// from the app: no DesignSystem, no SourcesKit, no Bedrock. The
/// widget runs in its own process with a tight memory cap and is built along with every
/// app build; everything it needs lies as JSON and a few images
/// in the app group (``SnapshotStore``). The only way back into the app
/// without opening it is the play/pause intent of the listening widget (``WeiterhoerenIntent``).
@main
struct AkariWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueReadingWidget()
        ContinueListeningWidget()
        ReadingStatisticsWidget()
    }
}
