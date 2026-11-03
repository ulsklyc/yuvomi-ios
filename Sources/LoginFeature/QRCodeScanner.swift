import AVFoundation
import SwiftUI
import VisionKit

/// Kamera-Scanner für QR-Codes. Die App nimmt VisionKit, die Vorschauen einen Platzhalter.
///
/// Was ein erkannter Code bedeutet, entscheidet `LoginModel.openScannedCode(_:)`; die Hülle
/// liefert nur den Inhalt.
@MainActor public protocol QRCodeScanner {
    /// Ob „QR-Code scannen“ erscheint.
    var isAvailable: Bool { get }
    /// Die Kameraansicht. `onCode` bekommt den Inhalt jedes neu erkannten QR-Codes.
    func makeView(onCode: @escaping @MainActor (String) -> Void) -> AnyView
}

/// `DataScannerViewController` nur für QR. Im Simulator gibt es keine Kamera, dort ist
/// `isSupported` false und der Button fehlt.
public struct VisionKitScanner: QRCodeScanner {
    public init() {}

    /// `isAvailable` ist erst nach der Freigabe der Kamera true. Vor der ersten Frage muss
    /// der Button trotzdem erscheinen, sonst käme die Freigabe nie.
    public var isAvailable: Bool {
        DataScannerViewController.isSupported
            && (DataScannerViewController.isAvailable || AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined)
    }

    public func makeView(onCode: @escaping @MainActor (String) -> Void) -> AnyView {
        AnyView(DataScannerView(onCode: onCode).ignoresSafeArea())
    }
}

private struct DataScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            try? scanner.startScanning()
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Void

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let text = barcode.payloadStringValue { onCode(text) }
            }
        }
    }
}
