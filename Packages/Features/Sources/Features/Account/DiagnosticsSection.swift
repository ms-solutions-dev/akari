import PerformanceDiagnostics
import SwiftUI

/// The "Diagnostics" section in the account screen: recording on/off, share the report,
/// clear.
///
/// **No live display:** measuring happens in the background and the report is what gets
/// read. Recording is off until switched on, since the hang watcher and frame timing cost
/// battery themselves, and battery is one of the things being investigated.
struct DiagnosticsSection: View {

    /// Stored in the general UserDefaults, not the profile's (the shell's
    /// `defaultAppStorage`): `Performance.launch(settings:)` reads it there at startup.
    /// Previously the switch lived in the profile, so recording was off after every restart
    /// although the switch showed "on".
    @AppStorage(Performance.recordKey, store: .standard) private var record = false
    @State private var report: Performance.ReportFiles?

    var body: some View {
        Section {
            Toggle(isOn: $record) {
                Label(app: "diagnostics.record", systemImage: "waveform.path.ecg")
            }
            .onChange(of: record) { _, to in Performance.record(to) }
            if let report {
                // Report, time series and requests together; the raw data for charts is included.
                ShareLink(items: report.all) {
                    Label(app: "diagnostics.share", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    report = Performance.report(edition: AccountsView.version)
                } label: {
                    Label(app: "diagnostics.create", systemImage: "doc.text.magnifyingglass")
                }
            }
            Button(role: .destructive) {
                Performance.clearOut()
                report = nil
            } label: {
                Label(app: "diagnostics.clear", systemImage: "trash")
            }
        } header: {
            Text(app: "diagnostics.title")
        } footer: {
            Text(app: "diagnostics.hint")
        }
        // A generated report is a snapshot; coming back creates a new one.
        .onDisappear { report = nil }
    }
}
