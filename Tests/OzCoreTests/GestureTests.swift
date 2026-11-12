import XCTest
@testable import OzCore

final class GestureTests: XCTestCase {
    func fingers(_ n: Int, y: Double, x: Double = 0.5) -> [Touch] {
        (0..<n).map { Touch(id: Int32($0), x: x + Double($0) * 0.1, y: y) }
    }

    func testVerticalThreeFingerSwipe() {
        let r = GestureRecognizer()
        var events: [GestureEvent] = []
        var t = 0.0
        for i in 0...10 {
            events += r.process(fingers(3, y: 0.3 + Double(i) * 0.02), time: t)
            t += 0.01
        }
        events += r.process(fingers(2, y: 0.5), time: t); t += 0.01
        events += r.process([], time: t)
        XCTAssertEqual(events.first, .swipeBegan)
        let total = events.compactMap { e -> Double? in if case .swipeChanged(let d) = e { return d }; return nil }.reduce(0, +)
        XCTAssertEqual(total, 0.2, accuracy: 1e-9)
        guard case .swipeEnded(let v)? = events.last(where: { if case .swipeEnded = $0 { return true }; return false }) else {
            return XCTFail("no end: \(events)")
        }
        XCTAssertGreaterThan(v, 1.0)
        XCTAssertFalse(events.contains { if case .tap = $0 { return true }; return false })
    }

    func testHorizontalSwipeIsIgnored() {
        let r = GestureRecognizer()
        var events: [GestureEvent] = []
        for i in 0...10 {
            events += r.process(fingers(3, y: 0.5, x: 0.2 + Double(i) * 0.03), time: Double(i) * 0.01)
        }
        events += r.process([], time: 0.2)
        XCTAssertTrue(events.isEmpty, "\(events)")
    }

    func testTwoFingersDoNothing() {
        let r = GestureRecognizer()
        var events: [GestureEvent] = []
        for i in 0...10 { events += r.process(fingers(2, y: 0.3 + Double(i) * 0.03), time: Double(i) * 0.01) }
        events += r.process([], time: 0.2)
        XCTAssertTrue(events.isEmpty)
    }

    func testThreeFingerDoubleTap() {
        let r = GestureRecognizer()
        var events: [GestureEvent] = []
        // Fingers land one after another, then lift: tap 1.
        events += r.process(fingers(1, y: 0.5), time: 0.00)
        events += r.process(fingers(3, y: 0.5), time: 0.02)
        events += r.process(fingers(3, y: 0.501), time: 0.08)
        events += r.process([], time: 0.12)
        XCTAssertEqual(events, [.tap(fingers: 3)])
        // Tap 2 shortly after -> double tap.
        events += r.process(fingers(3, y: 0.5), time: 0.30)
        events += r.process([], time: 0.38)
        XCTAssertEqual(events.last, .doubleTap(fingers: 3))
        // Slow second tap is not a double tap.
        events = []
        events += r.process(fingers(3, y: 0.5), time: 2.0)
        events += r.process([], time: 2.1)
        events += r.process(fingers(3, y: 0.5), time: 3.0)
        events += r.process([], time: 3.1)
        XCTAssertFalse(events.contains(.doubleTap(fingers: 3)))
    }

    func testLongPressIsNotTap() {
        let r = GestureRecognizer()
        var events = r.process(fingers(3, y: 0.5), time: 0)
        events += r.process([], time: 0.8)
        XCTAssertTrue(events.isEmpty)
    }

    func testSettingsParsing() {
        let s = Settings(json: ["gap": 4, "heights": [0.25, 0.75], "swipe": ["natural": false, "fingers": 4, "snap": "off"],
                                "doubleTap": ["action": "appExpose"], "topOverflow": "hide", "debug": true])
        XCTAssertEqual(s.gap, 4)
        XCTAssertEqual(s.heights, [0.25, 0.75])
        XCTAssertFalse(s.swipe.natural)
        XCTAssertEqual(s.swipe.fingers, 4)
        XCTAssertEqual(s.swipe.snap, .off)
        XCTAssertEqual(Settings(json: ["swipe": ["snap": true]]).swipe.snap, .always)
        XCTAssertEqual(Settings().captureScale, 1)
        XCTAssertEqual(Settings(json: ["captureScale": 0.5]).captureScale, 0.5)
        XCTAssertEqual(Settings(json: ["captureScale": 2]).captureScale, 1)
        XCTAssertEqual(Settings().swipe.snap, .near)
        XCTAssertEqual(s.doubleTap.action, "appExpose")
        XCTAssertEqual(s.topOverflow, .hide)
        XCTAssertTrue(s.debug)
    }

    func testSettingsReportWhatTheyCantUse() {
        // What the example config sets: nothing to report.
        var s = Settings()
        XCTAssertEqual(s.apply(["gap": 4, "heights": [0.25, 1], "passThroughApps": ["UTM"], "swipe": ["snap": false],
                                "scrollButtons": ["up": "mouse:3", "down": ""], "doubleTap": ["action": "binding:1"]]), [])
        // A misspelt name, values out of range or of the wrong kind: each named, none taken.
        s = Settings()
        let problems = s.apply(["gapp": 12, "newWindowPosition": "bottom", "defaultHeight": 2, "livePeek": "yes",
                                "heights": [0.5, 3], "swipe": ["snap": "sometimes", "speed": 2], "doubleTap": 3])
        XCTAssertEqual(Set(problems), [
            "gapp: no such setting",
            "newWindowPosition: \"bottom\" is not one of \"below\", \"above\", \"end\", \"start\"",
            "defaultHeight: 2 is not a number above 0, up to 1",
            "livePeek: \"yes\" is not true or false",
            "heights: that list is not a list of numbers above 0, up to 1",
            "swipe.snap: \"sometimes\" is not one of \"always\", \"near\", \"off\", true or false",
            "swipe.speed: no such setting",
            "doubleTap: 3 is not a group of settings ({ ... })",
        ])
        XCTAssertEqual(s.gap, 10)
        XCTAssertEqual(s.newWindowPosition, .below)
        XCTAssertEqual(s.defaultHeight, 0.5)
        XCTAssertTrue(s.livePeek)
        XCTAssertEqual(s.heights.count, 4)
        XCTAssertEqual(s.swipe.snap, .near)
    }
}
