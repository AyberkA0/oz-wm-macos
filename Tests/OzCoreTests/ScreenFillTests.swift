import CoreGraphics
import XCTest
@testable import OzCore

final class ScreenFillTests: XCTestCase {
    // A 1710x1074 visible area below a 38pt menu bar.
    let screen = CGRect(x: 0, y: 38, width: 1710, height: 1074)

    func testCoversIsNinetyFivePercentEachWay() {
        XCTAssertTrue(ScreenFill.covers(screen, visible: screen))
        XCTAssertTrue(ScreenFill.covers(CGRect(x: 0, y: 38, width: 1710 * 0.95, height: 1074 * 0.95), visible: screen))
        XCTAssertFalse(ScreenFill.covers(CGRect(x: 0, y: 38, width: 1710 * 0.94, height: 1074), visible: screen))
        XCTAssertFalse(ScreenFill.covers(CGRect(x: 0, y: 38, width: 1710, height: 1074 * 0.94), visible: screen))
    }

    func testOzsOwnFullScreenFrameDoesNotReachTheEdges() {
        // Oz fills the screen with an 8pt outer gap all round.
        XCTAssertFalse(ScreenFill.reaches(screen.insetBy(dx: 8, dy: 8), screen))
        XCTAssertTrue(ScreenFill.reaches(screen.insetBy(dx: 2, dy: 2), screen))
        XCTAssertTrue(ScreenFill.reaches(screen, screen))
    }

    func testTookAllowsFourPoints() {
        let target = screen.insetBy(dx: 8, dy: 8)
        XCTAssertTrue(ScreenFill.took(target, target))
        XCTAssertTrue(ScreenFill.took(target.insetBy(dx: 2, dy: 2), target))
        XCTAssertFalse(ScreenFill.took(target.insetBy(dx: 3, dy: 0), target))
    }

    func testResizedNeedsMoreThanTwentyPoints() {
        let r = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(ScreenFill.resized(CGRect(x: 100, y: 100, width: 820, height: 620), from: r))
        XCTAssertTrue(ScreenFill.resized(CGRect(x: 100, y: 100, width: 821, height: 600), from: r))
        XCTAssertTrue(ScreenFill.resized(CGRect(x: 100, y: 100, width: 800, height: 579), from: r))
    }

    func testGrewAndShrankNeedAFourHundredByTwentyStrip() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(ScreenFill.grew(CGRect(x: 0, y: 0, width: 800, height: 610), from: small))
        XCTAssertTrue(ScreenFill.grew(CGRect(x: 0, y: 0, width: 800, height: 611), from: small))
        XCTAssertTrue(ScreenFill.grew(screen, from: small))
        XCTAssertFalse(ScreenFill.shrank(CGRect(x: 0, y: 0, width: 800, height: 590), from: small))
        XCTAssertTrue(ScreenFill.shrank(CGRect(x: 0, y: 0, width: 800, height: 589), from: small))
        XCTAssertTrue(ScreenFill.shrank(small, from: screen))
    }
}
