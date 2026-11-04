import AVFoundation
import SwiftUI
import VisionKit

/// Kamera-Scanner für QR-Codes. Die App nimmt VisionKit, die Vorschauen einen Platzhalter.
///
/// Was ein erkannter Code bedeutet, entscheidet `LoginModel.openScannedCode(_:)`; die Hülle
/// liefert nur den Inhalt.
@MainActor public protocol QRCodeScanner {
    /// Ob „QR-Code scannen“ erscheint. Hängt nicht an der Freigabe der Kamera.
    var isAvailable: Bool { get }
    /// Die Freigabe, ohne zu fragen. `nil`, solange iOS noch nicht gefragt hat.
    func currentAccess() -> CameraAccess?
    /// Fragt nach der Kamera, falls iOS noch nicht gefragt hat. Ohne Freigabe zeigt das Blatt
    /// einen Hinweis statt einer schwarzen Kamera.
    func requestAccess() async -> CameraAccess
    /// Die Kameraansicht, nur wenn `requestAccess()` `.granted` ergab. `onCode` bekommt den Inhalt jedes neu
    /// erkannten QR-Codes.
    func makeView(onCode: @escaping @MainActor (String) -> Void) -> AnyView
}

/// Die Freigabe der Kamera, wie das Blatt sie braucht.
public enum CameraAccess: Equatable, Sendable {
    case granted
    /// Abgelehnt: In den Einstellungen lässt sich das ändern.
    case denied
    /// Gesperrt, etwa über Bildschirmzeit oder eine Geräteverwaltung. Den Schalter in den
    /// Einstellungen kann die Person dann nicht umlegen.
    case restricted

    /// `nil`, solange iOS noch nicht gefragt hat.
    init?(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: return nil
        case .authorized: self = .granted
        case .restricted: self = .restricted
        case .denied: self = .denied
        // Ein unbekannter Zustand soll nicht in die Einstellungen schicken.
        @unknown default: self = .restricted
        }
    }

    /// Ob der Weg in die Einstellungen etwas ändern kann.
    var offersSettings: Bool { self == .denied }
}

/// `DataScannerViewController` nur für QR. Im Simulator gibt es keine Kamera, dort ist
/// `isSupported` false und der Button fehlt.
public struct VisionKitScanner: QRCodeScanner {
    public init() {}

    /// Auf jedem Gerät, das scannen kann, auch ohne Freigabe: Dann erklärt das Blatt, warum
    /// die Kamera fehlt, statt dass der Knopf ohne Grund verschwindet.
    public var isAvailable: Bool { DataScannerViewController.isSupported }

    public func currentAccess() -> CameraAccess? {
        guard let access = CameraAccess(AVCaptureDevice.authorizationStatus(for: .video)) else { return nil }
        // Freigegeben, aber VisionKit kann trotzdem nicht scannen (etwa über eine
        // Geräteverwaltung): wie gesperrt, sonst bliebe die Kamera schwarz.
        return access == .granted && !DataScannerViewController.isAvailable ? .restricted : access
    }

    public func requestAccess() async -> CameraAccess {
        if let access = currentAccess() { return access }
        // Danach den Status lesen statt der Antwort: Auch eine Sperre ergibt `false`.
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return currentAccess() ?? .denied
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
        // Erst nach dem Einhängen starten, wie vorher hinter der Freigabe.
        Task { try? scanner.startScanning() }
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
