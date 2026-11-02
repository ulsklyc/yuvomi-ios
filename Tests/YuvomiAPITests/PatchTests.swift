import Foundation
import Testing
import YuvomiFixtures
@testable import YuvomiAPI

/// Die handgeschriebenen Eingaben unterscheiden "weglassen" und `null`, und der generierte
/// Client schickt das auch so ab. Genau das konnte der Generator allein nicht (S5).
@Suite struct PatchTests {
    @Test func unsetIsOmittedClearIsNullSetIsSent() throws {
        let input = CalendarEventUpdateInput(title: "Zahnarzt", description: .clear, location: .set("Praxis"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any]
        #expect(json?["title"] as? String == "Zahnarzt")
        #expect(json?["description"] is NSNull)
        #expect(json?["location"] as? String == "Praxis")
        #expect(json?.keys.contains("end_datetime") == false)
        #expect(json?.count == 3)
    }

    @Test func decodingKeepsTheThreeStates() throws {
        let data = Data(#"{"description":null,"location":"Praxis"}"#.utf8)
        let input = try JSONDecoder().decode(CalendarEventUpdateInput.self, from: data)
        #expect(input.description == .clear)
        #expect(input.location == .set("Praxis"))
        #expect(input.endDatetime == .unset)
    }

    @Test func clientSendsNullForAClearedEnd() async throws {
        let recorder = FixtureTransport.Recorder()
        let transport = FixtureTransport(
            overrides: ["updateCalendarEvent": try .fixture("calendar-event")],
            recorder: recorder
        )
        let client = Client(serverURL: URL(string: "https://fixture.invalid")!, transport: transport)

        _ = try await client.updateCalendarEvent(
            path: .init(id: 1),
            body: .json(.init(endDatetime: .clear, assignedTo: .set([2, 3])))
        )

        let sent = try #require(await recorder.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        #expect(json?["end_datetime"] is NSNull)
        #expect(json?["assigned_to"] as? [Int] == [2, 3])
        #expect(json?.count == 2)
    }
}
