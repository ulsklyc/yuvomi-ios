import Foundation
import Testing
import YuvomiCore

@Suite struct CalendarDayTests {
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 2026-11-02 23:30 UTC, in Berlin schon der 3. November.
    let lateEvening = Date(timeIntervalSince1970: 1_793_662_200)

    @Test func dayOfADateFollowsTheTimeZone() {
        #expect(CalendarDay(lateEvening, timeZone: berlin) == CalendarDay(year: 2026, month: 11, day: 3))
        #expect(CalendarDay(lateEvening, timeZone: .gmt) == CalendarDay(year: 2026, month: 11, day: 2))
    }

    @Test func startOfTheDayInTheTimeZone() {
        // 2026-11-03 00:00 in Berlin ist 2026-11-02 23:00 UTC.
        #expect(CalendarDay(year: 2026, month: 11, day: 3).start(timeZone: berlin) == Date(timeIntervalSince1970: 1_793_660_400))
    }

    /// `due_date` hin und zurück, mit führenden Nullen.
    @Test func isoRoundTrips() {
        let day = CalendarDay(year: 2026, month: 3, day: 7)
        #expect(day.iso == "2026-03-07")
        #expect(CalendarDay(iso: day.iso) == day)
    }
}
