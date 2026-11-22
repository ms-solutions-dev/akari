import AccountsKit
import CloudSync
import DesignSystem
import SwiftUI

#if os(iOS) && canImport(VisionKit)
    import AVFoundation
    import VisionKit
#endif

/// The camera sheet for the setup code, with a field for the link below it in case there
/// is no camera (simulator, iPad without permission) or the code arrived as text
/// (message, AirDrop).
///
/// Adoption is immediate: fingerprint trusted, addresses suggested, sheet closed. What
/// remains per server is name and password.
struct CodeScannerView: View {

    @Environment(AccountRegistry.self) private var accounts
    @Environment(ProfileRegistry.self) private var profiles
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var close
    @State private var text = ""
    @State private var invalid = false
    /// Whether the camera is allowed; `nil` while the permission question is still pending.
    @State private var allowed: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(iOS) && canImport(VisionKit)
                    if allowed == true, DataScannerViewController.isSupported,
                        DataScannerViewController.isAvailable
                    {
                        Camera(read: handleCode)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding()
                    } else if allowed == false {
                        Label(app: "setUp.camera.denied", systemImage: "camera.slash")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else if allowed == nil {
                        ProgressView().padding()
                    } else {
                        cameraMissing
                    }
                #else
                    cameraMissing
                #endif
                Form {
                    Section {
                        TextField(text: $text) {
                            Text(app: "setUp.code.paste")
                        }
                        .autocorrectionDisabled()
                        .onSubmit { handleCode(text) }
                        Button {
                            handleCode(text)
                        } label: {
                            Text(app: "setUp.code.adopt")
                        }
                        .disabled(text.isEmpty)
                    } footer: {
                        if invalid {
                            Text(app: "setUp.code.invalid").foregroundStyle(ColorTheme.failure.color)
                        } else {
                            Text(app: "setUp.code.text")
                        }
                    }
                }
            }
            .paper()
            .navigationTitle(Text(app: "setUp.code"))
            .toolbarTitleDisplayMode(.inline)
            .task(requestPermission)
            // The question "Adopt existing profile?" belongs on this sheet: it is
            // topmost, a dialog on the shell would never appear above it.
            .sharingQuestions(core.questions)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        close()
                    } label: {
                        Text(app: "action.cancel")
                    }
                }
            }
        }
    }

    /// **`isAvailable` is false without permission**, and VisionKit does not ask for
    /// permission by itself. On a fresh device the camera stayed off and only the link
    /// field showed. So the permission is requested here before the sheet decides what
    /// to show.
    @Sendable
    private func requestPermission() async {
        #if os(iOS) && canImport(VisionKit)
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
        #else
            allowed = false
        #endif
    }

    private var cameraMissing: some View {
        Label(app: "setUp.camera.missing", systemImage: "camera.slash")
            .foregroundStyle(.secondary)
            .padding()
    }

    private func handleCode(_ text: String) {
        guard let code = SetupCode(text: text) else {
            invalid = true
            return
        }
        // "Add device": the code carries a sharing; the core accepts it,
        // creates the profile (or adopts one with the same name after confirmation) and
        // switches to it; the accounts arrive there as a suggestion.
        if code.sharing != nil {
            Task {
                do throws(CloudError) {
                    _ = try await core.acceptSharing(code)
                    close()
                } catch {
                    invalid = true
                }
            }
            return
        }
        accounts.adopt(code)
        // The per-person code names the first profile, as long as it is the only one
        // and has no account yet; a second profile keeps its own name.
        if let person = code.person { profiles.rename(to: person, ifUntouched: !accounts.configured) }
        close()
    }
}

#if os(iOS) && canImport(VisionKit)
    /// VisionKit's scanner, restricted to QR codes. Starts once it is in the window and
    /// reports the first code with content once, then stops so that the same code is not
    /// adopted three times.
    private struct Camera: UIViewControllerRepresentable {

        let read: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
            if !scanner.isScanning { try? scanner.startScanning() }
        }

        static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator)
        {
            scanner.stopScanning()
        }

        func makeCoordinator() -> Coordinator { Coordinator(read: read) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let read: (String) -> Void
            private var done = false

            init(read: @escaping (String) -> Void) { self.read = read }

            func dataScanner(
                _ scanner: DataScannerViewController, didAdd added: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                guard !done else { return }
                for fall in added {
                    if case .barcode(let code) = fall, let content = code.payloadStringValue, !content.isEmpty
                    {
                        done = true
                        scanner.stopScanning()
                        read(content)
                        return
                    }
                }
            }
        }
    }
#endif
