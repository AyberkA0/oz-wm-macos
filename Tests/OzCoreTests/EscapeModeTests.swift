import CoreGraphics
import XCTest
@testable import OzCore

final class EscapeModeTests: XCTestCase {
    let area = CGRect(x: 0, y: 40, width: 1000, height: 800)
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 850)

    func testFrameShrinksToItsShareAroundItsMiddle() {
        let f = EscapeMode.frame(for: CGRect(x: 100, y: 40, width: 900, height: 800), in: area)
        // Half the width is the tighter limit; the shape stays 9:8.
        XCTAssertEqual(f.size, CGSize(width: 500, height: 444))
        XCTAssertEqual(f.midX, 550, accuracy: 1)
        XCTAssertTrue(area.contains(f))
    }

    func testSmallWindowKeepsItsSize() {
        let f = EscapeMode.frame(for: CGRect(x: 900, y: 700, width: 300, height: 200), in: area)
        XCTAssertEqual(f.size, CGSize(width: 300, height: 200))
        XCTAssertTrue(area.contains(f))  // pulled inside
    }

    func testOffEdgeTakesTheNearerSide() {
        let l = EscapeMode.offEdge(CGRect(x: 50, y: 100, width: 400, height: 300), screen: screen)
        XCTAssertEqual(l?.maxX, 1)
        let r = EscapeMode.offEdge(CGRect(x: 600, y: 100, width: 400, height: 300), screen: screen)
        XCTAssertEqual(r?.minX, 999)
        XCTAssertEqual(r?.minY, 100)
    }

    func testOffEdgeAvoidsAnotherDisplay() {
        let leftDisplay = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        let f = EscapeMode.offEdge(CGRect(x: 50, y: 100, width: 400, height: 300), screen: screen, others: [leftDisplay])
        XCTAssertEqual(f?.minX, 999)
        let rightDisplay = CGRect(x: 1000, y: 0, width: 1200, height: 900)
        XCTAssertNil(EscapeMode.offEdge(CGRect(x: 50, y: 100, width: 400, height: 300), screen: screen,
                                         others: [leftDisplay, rightDisplay]))
    }

    func testDodgeGoesFarFromThePointer() {
        let f = CGRect(x: 0, y: 40, width: 400, height: 300)
        let p = CGPoint(x: 100, y: 100)  // on it, top left
        let to = EscapeMode.dodge(f, from: p, in: area)
        XCTAssertEqual(to.maxX, area.maxX)
        XCTAssertEqual(to.maxY, area.maxY)
        XCTAssertFalse(EscapeMode.isNear(p, to))
    }

    func testDodgePrefersTheShorterMoveWhenAsFar() {
        // Pointer in the middle at the top: bottom left and bottom right are as far; the
        // window is on the right already.
        let f = CGRect(x: 600, y: 40, width: 400, height: 300)
        let to = EscapeMode.dodge(f, from: CGPoint(x: 500, y: 60), in: area)
        XCTAssertEqual(to.minX, 600)
        XCTAssertEqual(to.maxY, area.maxY)
    }

    func testScrollingGrowsTowardTheOriginalSizeAndNoFurther() {
        let original = CGSize(width: 800, height: 600)
        let f = CGRect(x: 300, y: 300, width: 400, height: 300)
        let bigger = EscapeMode.resized(f, by: 0.2, original: original, in: area)
        XCTAssertGreaterThan(bigger.width, f.width)
        XCTAssertEqual(bigger.width / bigger.height, 4.0 / 3, accuracy: 0.01)
        XCTAssertEqual(bigger.midX, f.midX, accuracy: 1)
        let most = EscapeMode.resized(f, by: 5, original: original, in: area)
        XCTAssertEqual(most.size, original)
        XCTAssertTrue(area.contains(most))
        let least = EscapeMode.resized(f, by: -5, original: original, in: area)
        XCTAssertEqual(least.width, EscapeMode.minWidth)
    }

    func testShrinkingAtTheSmallestDoesNotMoveIt() {
        let original = CGSize(width: 800, height: 600)
        var f = EscapeMode.resized(CGRect(x: 301, y: 301, width: 401, height: 301), by: -5, original: original, in: area)
        let smallest = f
        for _ in 0..<20 { f = EscapeMode.resized(f, by: -0.3, original: original, in: area) }
        XCTAssertEqual(f, smallest)
    }

    func testFittedKeepsTheSizeAndComesInside() {
        let f = EscapeMode.fitted(CGRect(x: 800, y: 700, width: 500, height: 300), in: area)
        XCTAssertEqual(f.size, CGSize(width: 500, height: 300))
        XCTAssertEqual(f.maxX, area.maxX)
        XCTAssertEqual(f.maxY, area.maxY)
    }

    func testNear() {
        let f = CGRect(x: 100, y: 100, width: 100, height: 100)
        XCTAssertTrue(EscapeMode.isNear(CGPoint(x: 150, y: 150), f))
        XCTAssertFalse(EscapeMode.isNear(CGPoint(x: 195, y: 150), f))  // at its edge
        XCTAssertFalse(EscapeMode.isNear(CGPoint(x: 210, y: 150), f))
    }
}
