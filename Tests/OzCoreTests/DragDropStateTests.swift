import CoreGraphics
import XCTest
@testable import OzCore

final class DragDropStateTests: XCTestCase {
    // 1000pt viewport at y=50, gap 10 (as in StripTests).
    let params = LayoutParams(viewport: CGRect(x: 10, y: 50, width: 1000, height: 1000),
                              hardTop: 40, hardBottom: 1100, gap: 10, minVisible: 80)

    func makeStrip(_ heights: [CGFloat]) -> Strip {
        let s = Strip()
        for (i, h) in heights.enumerated() { s.insert(WinID(i + 1), height: h, anchor: nil, position: .end) }
        return s
    }

    // MARK: Drop slots

    func testDropBetweenRows() {
        let s = makeStrip([300, 300, 300])   // rows at y 50, 360, 670
        // Cursor in the upper half of row 2: above it. Window 3 is dragged.
        let a = s.dropSlot(at: CGPoint(x: 500, y: 400), dragging: 3, params: params)
        XCTAssertEqual(a?.slot, .row(before: 2))
        // The line sits in the gap between rows 1 and 2, across the row.
        XCTAssertEqual(a?.line, CGRect(x: 10, y: 352, width: 1000, height: 6))
        // Lower half of the last row: after it.
        XCTAssertEqual(s.dropSlot(at: CGPoint(x: 500, y: 900), dragging: 1, params: params)?.slot, .row(before: nil))
    }

    func testDropWhereItAlreadyIsShowsNothing() {
        let s = makeStrip([300, 300, 300])
        // Window 2 dropped just above or below its own row: no move.
        XCTAssertNil(s.dropSlot(at: CGPoint(x: 500, y: 400), dragging: 2, params: params))
        XCTAssertNil(s.dropSlot(at: CGPoint(x: 500, y: 620), dragging: 2, params: params))
    }

    func testDropBesideAWindow() {
        let s = makeStrip([300, 300])
        // Near the right edge of window 1 (its right quarter): beside it, on the right.
        let r = s.dropSlot(at: CGPoint(x: 950, y: 200), dragging: 2, params: params)
        XCTAssertEqual(r?.slot, .beside(1, right: true))
        XCTAssertEqual(r?.line, CGRect(x: 1012, y: 50, width: 6, height: 300))
        XCTAssertEqual(s.dropSlot(at: CGPoint(x: 40, y: 200), dragging: 2, params: params)?.slot, .beside(1, right: false))
        // In its middle: between rows instead.
        XCTAssertEqual(s.dropSlot(at: CGPoint(x: 500, y: 100), dragging: 2, params: params)?.slot, .row(before: 1))
    }

    func testDropIntoAnEmptyStrip() {
        XCTAssertEqual(Strip().dropSlot(at: CGPoint(x: 500, y: 500), dragging: 9, params: params)?.slot, .row(before: nil))
    }

    // MARK: Scrolling under a drag

    func testDragScrollOnlyInTheEdgeBands() {
        let zone = CGRect(x: 0, y: 40, width: 1000, height: 1000)   // bands: 150 pt
        func v(_ y: CGFloat, scroll: CGFloat = 500) -> (velocity: CGFloat, inBand: Bool) {
            DragScroll.velocity(cursorY: y, zone: zone, viewportHeight: 1000, scroll: scroll, maxScroll: 2000)
        }
        // The middle never scrolls.
        XCTAssertEqual(v(540).velocity, 0)
        XCTAssertFalse(v(540).inBand)
        // Top band scrolls up, bottom band down, faster at the very edge.
        XCTAssertLessThan(v(60).velocity, v(170).velocity)
        XCTAssertLessThan(v(60).velocity, 0)
        XCTAssertGreaterThan(v(1030).velocity, v(900).velocity)
        XCTAssertGreaterThan(v(900).velocity, 0)
        XCTAssertEqual(v(40).velocity, -1500, accuracy: 0.5)
        // At the top of the strip there's nothing more to show above.
        XCTAssertEqual(v(60, scroll: 0).velocity, 0)
        XCTAssertTrue(v(60, scroll: 0).inBand)
    }

    // MARK: Saving and restoring

    func testStateRoundTripsThroughJSON() throws {
        let s = makeStrip([300, 400])
        s.setLoneWidth(2, 0.5)
        s.setLoneOffset(2, 0.25)
        s.scrollY = 120
        s.focused = 2
        let state = s.state { WindowDescription(id: $0, app: "App\($0)", bundleID: "b.\($0)", title: "T\($0)") }
        let decoded = try JSONDecoder().decode(StripState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.rows[1].windows[0].weight, 0.5)
        XCTAssertEqual(decoded.rows[1].windows[0].offset, 0.25)
    }

    func testRestorePutsWindowsBackAndKeepsNewOnesAfter() {
        // Saved: [2] [1, 3] (1 and 3 side by side), focus on 3, scrolled.
        let saved = StripState(rows: [
            .init(height: 500, windows: [.init(id: 2)]),
            .init(height: 350, windows: [.init(id: 1, weight: 0.6), .init(id: 3, weight: 0.4)]),
        ], scroll: 200, focused: 3)
        // Now: [1] [2] [3] [4] (4 is new).
        let s = makeStrip([300, 300, 300, 300])
        let used = s.restore(saved, maxHeight: 1000) { w, used in s.contains(w.id) && !used.contains(w.id) ? w.id : nil }
        XCTAssertEqual(used, [1, 2, 3])
        XCTAssertEqual(s.rows.map(\.windows), [[2], [1, 3], [4]])
        XCTAssertEqual(s.rows.map(\.height), [500, 350, 300])
        XCTAssertEqual(s.weight(1), 0.6, accuracy: 0.001)
        XCTAssertEqual(s.focused, 3)
        XCTAssertEqual(s.scrollY, 200)
    }

    func testRestoreWithNoWindowMatchedLeavesTheStripAlone() {
        // Saved for windows that are gone (their apps restarted): its scroll isn't this strip's.
        let saved = StripState(rows: [.init(height: 500, windows: [.init(id: 99)])], scroll: 2500, focused: 99)
        let s = makeStrip([300, 300])
        s.scrollY = 0
        s.focused = 2
        let used = s.restore(saved, maxHeight: 1000) { _, _ in nil }
        XCTAssertTrue(used.isEmpty)
        XCTAssertEqual(s.rows.map(\.windows), [[1], [2]])
        XCTAssertEqual(s.scrollY, 0)
        XCTAssertEqual(s.focused, 2)
    }

    func testPresetMatchingFallsBackToTheAppsNextWindow() {
        let live = [WindowDescription(id: 50, app: "Google Chrome", bundleID: "com.google.Chrome", title: "New Tab"),
                    WindowDescription(id: 51, app: "Google Chrome", bundleID: "com.google.Chrome", title: "Docs"),
                    WindowDescription(id: 52, app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", title: "WhatsApp")]
        // Saved: two Chrome windows (titles that no longer exist except "Docs") and WhatsApp.
        let docs = StripState.Window(id: 1, app: "Google Chrome", bundleID: "com.google.Chrome", title: "Docs")
        let mail = StripState.Window(id: 2, app: "Google Chrome", bundleID: "com.google.Chrome", title: "Inbox")
        let chat = StripState.Window(id: 3, app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", title: "WhatsApp")
        // The same title wins; then the app's next unused window; never another app's.
        XCTAssertEqual(WindowMatcher.matchLoosely(docs, in: live, excluding: []), 51)
        XCTAssertEqual(WindowMatcher.matchLoosely(mail, in: live, excluding: [51]), 50)
        XCTAssertNil(WindowMatcher.matchLoosely(mail, in: live, excluding: [50, 51]))
        XCTAssertEqual(WindowMatcher.matchLoosely(chat, in: live, excluding: []), 52)
        XCTAssertNil(WindowMatcher.matchLoosely(.init(id: 4, app: "Mail", bundleID: "com.apple.mail", title: "x"),
                                                in: live, excluding: []))
    }

    func testPresetRoundTripsAndNamesItself() throws {
        let apps = [Preset.App(bundleID: "com.google.Chrome", name: "Chrome", path: nil),
                    Preset.App(bundleID: "com.anthropic.claudefordesktop", name: "Claude", path: nil),
                    Preset.App(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: nil),
                    Preset.App(bundleID: "com.apple.Terminal", name: "Terminal", path: nil)]
        XCTAssertEqual(Preset.defaultName(for: Array(apps.prefix(3))), "Chrome, Claude, WhatsApp")
        XCTAssertEqual(Preset.defaultName(for: apps), "Chrome, Claude and 2 more")
        let p = Preset(name: "Work", created: Date(timeIntervalSince1970: 0),
                       desktop: StripState(rows: [.init(height: 400, windows: [.init(id: 1, app: "Chrome")])]),
                       scrollArea: [0.5, 0, 0.5, 1], apps: apps)
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(p)), p)
    }

    func testMatchingByIdThenByAppAndTitle() {
        let live = [WindowDescription(id: 10, app: "Terminal", bundleID: "com.apple.Terminal", title: "zsh"),
                    WindowDescription(id: 11, app: "Safari", bundleID: "com.apple.Safari", title: "Docs"),
                    WindowDescription(id: 12, app: "Safari", bundleID: "com.apple.Safari", title: "News")]
        // Same id, same app: that window.
        XCTAssertEqual(WindowMatcher.match(.init(id: 10, app: "Terminal", bundleID: "com.apple.Terminal", title: "old"),
                                           in: live, excluding: []), 10)
        // The app restarted (new ids): found by app and title.
        let news = StripState.Window(id: 99, app: "Safari", bundleID: "com.apple.Safari", title: "News")
        XCTAssertEqual(WindowMatcher.match(news, in: live, excluding: []), 12)
        XCTAssertNil(WindowMatcher.match(news, in: live, excluding: [12]))
        // An id that now belongs to another app is not a match.
        XCTAssertNil(WindowMatcher.match(.init(id: 11, app: "Mail", bundleID: "com.apple.mail", title: "Docs"),
                                         in: live, excluding: []))
    }
}
