import AVFoundation
import Testing
@testable import LoginFeature

/// Wie die Freigabe von iOS im Blatt ankommt. Gesperrt ist nicht abgelehnt: Bei Bildschirmzeit
/// lässt sich der Schalter in den Einstellungen nicht umlegen, der Weg dorthin hülfe nicht.
@Suite struct CameraAccessTests {
    @Test func aRestrictedCameraIsNotReportedAsRefused() {
        #expect(CameraAccess(.restricted) == .restricted)
        #expect(CameraAccess(.restricted)?.offersSettings == false)
    }

    @Test func aRefusedCameraPointsToSettings() {
        #expect(CameraAccess(.denied) == .denied)
        #expect(CameraAccess(.denied)?.offersSettings == true)
    }

    @Test func anAllowedCameraScans() {
        #expect(CameraAccess(.authorized) == .granted)
        #expect(CameraAccess(.authorized)?.offersSettings == false)
    }

    /// Vor der Frage von iOS gibt es noch keine Antwort, auch kein Nein.
    @Test func anUnaskedCameraHasNoAnswerYet() {
        #expect(CameraAccess(.notDetermined) == nil)
    }
}
