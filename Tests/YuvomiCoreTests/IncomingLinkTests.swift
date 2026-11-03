import Foundation
import Testing
import YuvomiCore

@Suite struct IncomingLinkTests {
    let link = URL(string: "yuvomi://pair?server=https%3A%2F%2Fother.example.com&code=ACDE34FGHJ")!

    @Test func withoutSessionTheLinkGoesToTheLogin() {
        #expect(IncomingLink(url: link, current: nil) == .pairing(link))
    }

    /// Ein fremder Link darf eine bestehende Sitzung nicht ersetzen (S3, Q3 im Plan).
    @Test func whileSignedInTheLinkIsRefused() {
        let session = Session(server: URL(string: "https://yuvomi.example.com")!, credential: "ydc_current")
        #expect(IncomingLink(url: link, current: session) == .refusedWhileSignedIn)
    }
}
