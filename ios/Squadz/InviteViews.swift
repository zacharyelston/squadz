import CoreImage
import CoreImage.CIFilterBuiltins
import SquadKit
import SquadLink
import SwiftUI
import VisionKit

/// The leader's invite, as a QR code for the others to scan.
struct InviteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let invite = model.invite {
                    QRCodeView(invite.url(scheme: SquadService.squadz.scheme).absoluteString)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: 320)
                        .accessibilityLabel("Invite code for \(invite.name)")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < invite.expires {
                            Text("Anyone who scans this in the next \(Text(invite.expires, style: .timer)) joins.")
                        } else {
                            Text("This code has expired.")
                        }
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    Text("Show it only to your squad. Close it when everyone is in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("New code", systemImage: "arrow.clockwise") { model.openJoining() }
                        .buttonStyle(.bordered)
                } else {
                    ContentUnavailableView("Joining is closed", systemImage: "lock",
                                           description: Text("Nobody new can join until you open it again."))
                    Button("Open joining", systemImage: "qrcode") { model.openJoining() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Invite to \(model.squad?.name ?? "squad")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Done leaves joining open until the code expires.
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close joining") {
                        model.closeJoining()
                        dismiss()
                    }
                }
            }
            .onAppear { if model.invite == nil { model.openJoining() } }
        }
    }
}

/// The camera scanner. It hands what it read to the model, which only offers to join.
struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if QRScanner.isAvailable {
                    QRScanner { code in
                        dismiss()
                        model.offer(code)
                    }
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityLabel("Camera viewfinder for the invite code")
                    Text("Point the camera at the code on the leader's phone.")
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Camera scanning isn't available", systemImage: "camera",
                                           description: Text("Allow camera access for Squadz in Settings."))
                }
            }
            .padding()
            .navigationTitle("Scan an invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Draws text as a QR code, sharp at any size. Always black on white with a quiet zone, so it
/// scans in dark mode too.
struct QRCodeView: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white)
        } else {
            Color.white
        }
    }

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// VisionKit's live QR scanner. Calls `onCode` once, with the first QR text.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    /// False on simulators, on devices without a camera, and when camera access is denied.
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}
