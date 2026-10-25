@testable import PresenceCore
import XCTest

final class KeepAwakeCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Durations

    func testPresetsMatchTheRequestedList() {
        XCTAssertEqual(KeepAwakeDuration.presets, [.minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(240), .indefinitely])
    }

    func testMinuteDeadlines() {
        XCTAssertEqual(KeepAwakeDuration.minutes(15).deadline(from: now), now.addingTimeInterval(900))
        XCTAssertEqual(KeepAwakeDuration.minutes(240).deadline(from: now), now.addingTimeInterval(4 * 3600))
        XCTAssertNil(KeepAwakeDuration.indefinitely.deadline(from: now))
    }

    func testCustomDurationIsClamped() {
        XCTAssertEqual(KeepAwakeDuration.custom(minutes: 0), .minutes(1))
        XCTAssertEqual(KeepAwakeDuration.custom(minutes: -5), .minutes(1))
        XCTAssertEqual(KeepAwakeDuration.custom(minutes: 90), .minutes(90))
        XCTAssertEqual(KeepAwakeDuration.custom(minutes: 100_000), .minutes(24 * 60))
    }

    func testUntilLaterToday() {
        // now = 2027-01-15 08:00 UTC
        let deadline = KeepAwakeDuration.until(hour: 18, minute: 30).deadline(from: now, calendar: utc)!
        let parts = utc.dateComponents([.day, .hour, .minute], from: deadline)
        XCTAssertEqual(parts.day, utc.component(.day, from: now))
        XCTAssertEqual(parts.hour, 18)
        XCTAssertEqual(parts.minute, 30)
    }

    func testUntilAPassedTimeMeansTomorrow() {
        let hour = utc.component(.hour, from: now)
        let deadline = KeepAwakeDuration.until(hour: hour - 1, minute: 0).deadline(from: now, calendar: utc)!
        XCTAssertGreaterThan(deadline, now)
        XCTAssertLessThanOrEqual(deadline.timeIntervalSince(now), 24 * 3600)
        XCTAssertEqual(utc.component(.hour, from: deadline), hour - 1)
    }

    func testLabels() {
        XCTAssertEqual(KeepAwakeDuration.minutes(15).label, "15 min")
        XCTAssertEqual(KeepAwakeDuration.minutes(60).label, "1 hour")
        XCTAssertEqual(KeepAwakeDuration.minutes(240).label, "4 hours")
        XCTAssertEqual(KeepAwakeDuration.minutes(90).label, "1 h 30 min")
        XCTAssertEqual(KeepAwakeDuration.until(hour: 7, minute: 5).label, "Until 07:05")
    }

    func testDurationsSurviveCoding() throws {
        for duration in KeepAwakeDuration.presets + [.until(hour: 9, minute: 15), .minutes(77)] {
            let data = try JSONEncoder().encode(duration)
            XCTAssertEqual(try JSONDecoder().decode(KeepAwakeDuration.self, from: data), duration)
        }
    }

    // MARK: Holds and modes

    func testNoHoldsMeansNoAssertion() {
        let state = KeepAwakeState()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.effectiveMode)
        XCTAssertNil(state.nextDeadline)
    }

    func testDisplayModeWinsOverSystemMode() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .system, deadline: nil)
        XCTAssertEqual(state.effectiveMode, .system)
        state.activate(.presentation, mode: .display, deadline: nil)
        XCTAssertEqual(state.effectiveMode, .display)
        state.deactivate(.presentation)
        XCTAssertEqual(state.effectiveMode, .system)
    }

    func testAppQuittingDoesNotEndManualSession() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .display, deadline: now.addingTimeInterval(600))
        state.activate(.app(bundleID: "com.example.slides"), mode: .display, deadline: nil)
        state.deactivate(.app(bundleID: "com.example.slides"))
        XCTAssertTrue(state.isActive)
        XCTAssertNotNil(state.hold(for: .manual))
    }

    func testExpiryRemovesOnlyDueHolds() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .display, deadline: now.addingTimeInterval(60))
        state.activate(.presentation, mode: .display, deadline: nil)
        XCTAssertEqual(state.nextDeadline, now.addingTimeInterval(60))
        XCTAssertEqual(state.expire(now: now.addingTimeInterval(59)), [])
        XCTAssertEqual(state.expire(now: now.addingTimeInterval(60)), [.manual])
        XCTAssertNil(state.hold(for: .manual))
        XCTAssertTrue(state.isActive)
        XCTAssertNil(state.nextDeadline)
    }

    func testExpiryAfterSleepCatchesUp() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .system, deadline: now.addingTimeInterval(900))
        // The Mac slept through the deadline; the first check after waking ends it.
        XCTAssertEqual(state.expire(now: now.addingTimeInterval(5 * 3600)), [.manual])
        XCTAssertFalse(state.isActive)
    }

    func testRemainingTime() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .display, deadline: now.addingTimeInterval(125))
        XCTAssertEqual(state.remaining(for: .manual, now: now), 125)
        XCTAssertEqual(state.remaining(for: .manual, now: now.addingTimeInterval(500)), 0)
        state.activate(.manual, mode: .display, deadline: nil)
        XCTAssertNil(state.remaining(for: .manual, now: now))
    }

    func testChangingModeLeavesPresentationOnDisplay() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .display, deadline: nil)
        state.activate(.presentation, mode: .display, deadline: nil)
        state.setUserMode(.system)
        XCTAssertEqual(state.hold(for: .manual)?.mode, .system)
        XCTAssertEqual(state.hold(for: .presentation)?.mode, .display)
    }

    func testLowBatteryEndsManualAndAppButNotPresentation() {
        var state = KeepAwakeState()
        state.activate(.manual, mode: .display, deadline: nil)
        state.activate(.app(bundleID: "us.zoom.xos"), mode: .display, deadline: nil)
        state.activate(.presentation, mode: .display, deadline: nil)
        let ended = Set(state.endForLowBattery())
        XCTAssertEqual(ended, [.manual, .app(bundleID: "us.zoom.xos")])
        XCTAssertNotNil(state.hold(for: .presentation))
    }

    func testBatteryCutoffRule() {
        XCTAssertTrue(BatteryCutoff.shouldEnd(onBattery: true, percent: 19, threshold: 20))
        XCTAssertFalse(BatteryCutoff.shouldEnd(onBattery: true, percent: 20, threshold: 20))
        XCTAssertFalse(BatteryCutoff.shouldEnd(onBattery: false, percent: 3, threshold: 20))
        XCTAssertFalse(BatteryCutoff.shouldEnd(onBattery: true, percent: nil, threshold: 20))
    }

    func testRemainingTimeFormat() {
        XCTAssertEqual(RemainingTime.format(0), "0:00")
        XCTAssertEqual(RemainingTime.format(59.2), "1:00")
        XCTAssertEqual(RemainingTime.format(42 * 60 + 10), "42:10")
        XCTAssertEqual(RemainingTime.format(3600 + 5 * 60 + 3), "1:05:03")
        XCTAssertEqual(RemainingTime.format(-4), "0:00")
    }
}
