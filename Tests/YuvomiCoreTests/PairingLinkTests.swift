import Foundation
import Testing
import YuvomiCore

@Suite struct PairingLinkTests {
    @Test func readsServerAndCodeFromTheLinkTheServerBuilds() throws {
        let link = try #require(PairingLink(url: URL(string: "yuvomi://pair?server=https%3A%2F%2Fyuvomi.example.com&code=ACDE34FGHJ")!))

        #expect(link.server == URL(string: "https://yuvomi.example.com")!)
        #expect(link.code == "ACDE34FGHJ")
    }

    @Test func normalizesCodeAndServerLikeTheServerCompares() throws {
        let link = try #require(PairingLink(url: URL(string: "yuvomi://pair?server=HTTP%3A%2F%2FLocalHost%3A3901%2F&code=acde-34fg%20hj")!))

        #expect(link.server == URL(string: "http://localhost:3901")!)
        #expect(link.code == "ACDE34FGHJ")
    }

    @Test(arguments: [
        "https://yuvomi.example.com/pair?server=https%3A%2F%2Fyuvomi.example.com&code=ACDE34FGHJ",
        "yuvomi://login?server=https%3A%2F%2Fyuvomi.example.com&code=ACDE34FGHJ",
        "yuvomi://pair?code=ACDE34FGHJ",
        "yuvomi://pair?server=https%3A%2F%2Fyuvomi.example.com",
        "yuvomi://pair?server=https%3A%2F%2Fyuvomi.example.com&code=%20-%20",
        "yuvomi://pair?server=ftp%3A%2F%2Fyuvomi.example.com&code=ACDE34FGHJ",
        "yuvomi://pair?server=https%3A%2F%2Fyuvomi.example.com%2Fapp&code=ACDE34FGHJ",
        "yuvomi://pair?server=https%3A%2F%2Fa.example.com&server=https%3A%2F%2Fb.example.com&code=ACDE34FGHJ",
    ])
    func refusesLinksTheServerDoesNotBuild(_ link: String) {
        #expect(PairingLink(url: URL(string: link)!) == nil)
    }
}
