import CoreGraphics
import XCTest
@testable import OzCore

final class OutsideRegionsTests: XCTestCase {
    // A 1710x1074 usable screen starting below a 38pt menu bar.
    let screen = CGRect(x: 0, y: 38, width: 1710, height: 1074)

    func testRightHalfZoneLeavesTheLeftHalf() {
        let zone = CGRect(x: 855, y: 38, width: 855, height: 1074)
        XCTAssertEqual(OutsideRegions.compute(outer: screen, zone: zone),
                       [CGRect(x: 0, y: 38, width: 855, height: 1074)])
    }

    func testWholeScreenZoneHasNoOutside() {
        XCTAssertEqual(OutsideRegions.compute(outer: screen, zone: screen), [])
    }

    func testThinSidesAreLeftOut() {
        // 100pt to the left is too thin for a window; the right side remains.
        let zone = CGRect(x: 100, y: 38, width: 1000, height: 1074)
        XCTAssertEqual(OutsideRegions.compute(outer: screen, zone: zone),
                       [CGRect(x: 1100, y: 38, width: 610, height: 1074)])
    }

    func testCornerZoneGivesTheLongerStripTheCorner() {
        // Zone in the bottom right: an L-shaped outside of two rectangles. The screen is wider
        // than tall, so the top strip running the full width is the longest possible.
        let zone = CGRect(x: 600, y: 438, width: 1110, height: 674)
        XCTAssertEqual(OutsideRegions.compute(outer: screen, zone: zone), [
            CGRect(x: 0, y: 38, width: 1710, height: 400),
            CGRect(x: 0, y: 438, width: 600, height: 674),
        ])
    }

    func testCenteredZoneCoversEverySideWithFourRectangles() {
        let zone = CGRect(x: 400, y: 238, width: 900, height: 674)
        let regions = OutsideRegions.compute(outer: screen, zone: zone)
        XCTAssertEqual(regions.count, 4)
        // Together with the zone they tile the screen exactly: no overlap, nothing missing.
        let area = regions.reduce(zone.width * zone.height) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, screen.width * screen.height)
        for (i, a) in regions.enumerated() {
            XCTAssertTrue(a.intersection(zone).isEmpty || a.intersection(zone).width * a.intersection(zone).height == 0)
            for b in regions[(i + 1)...] {
                let o = a.intersection(b)
                XCTAssertTrue(o.isNull || o.width * o.height == 0)
            }
        }
        // The longest rectangle runs the full width of the screen.
        XCTAssertEqual(regions.map { max($0.width, $0.height) }.max(), 1710)
    }

    func testFramesSplitAlongTheLongSide() {
        // A tall region: two windows stacked, each half the height.
        let tall = CGRect(x: 0, y: 0, width: 600, height: 1000)
        XCTAssertEqual(OutsideRegions.frames(in: tall, count: 2, gap: 10), [
            CGRect(x: 10, y: 10, width: 580, height: 485),
            CGRect(x: 10, y: 505, width: 580, height: 485),
        ])
        // A wide region: side by side, each half the width.
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 400)
        XCTAssertEqual(OutsideRegions.frames(in: wide, count: 2, gap: 10), [
            CGRect(x: 10, y: 10, width: 485, height: 380),
            CGRect(x: 505, y: 10, width: 485, height: 380),
        ])
    }

    func testSharesSetEachWindowsLength() {
        // 1000 high, 10 pt gaps: 970 for two windows, a third and two thirds.
        let tall = CGRect(x: 0, y: 0, width: 600, height: 1000)
        XCTAssertEqual(OutsideRegions.frames(in: tall, shares: [1, 2], gap: 10), [
            CGRect(x: 10, y: 10, width: 580, height: 323),
            CGRect(x: 10, y: 343, width: 580, height: 647),
        ])
        XCTAssertEqual(OutsideRegions.frames(in: tall, shares: [1, 1], gap: 10), OutsideRegions.frames(in: tall, count: 2, gap: 10))
    }

    func testDraggingASharedEdgeMovesItsNeighbour() {
        let tall = CGRect(x: 0, y: 0, width: 600, height: 1000)
        let even: [CGFloat] = [1, 1, 1]
        let before = OutsideRegions.frames(in: tall, shares: even, gap: 10)
        // The middle window's top edge dragged 100 pt up: the one above gets shorter by that.
        var f = before[1]
        f.origin.y -= 100
        f.size.height += 100
        let shares = OutsideRegions.shares(resizing: 1, to: f, in: tall, shares: even, gap: 10)!
        let after = OutsideRegions.frames(in: tall, shares: shares, gap: 10)
        XCTAssertEqual(after[0].height, before[0].height - 100)
        XCTAssertEqual(after[1], f)
        XCTAssertEqual(after[2], before[2])
        // Its bottom edge dragged down: the one below gives the room.
        var g = before[1]
        g.size.height += 50
        let below = OutsideRegions.frames(in: tall, shares: OutsideRegions.shares(resizing: 1, to: g, in: tall, shares: even, gap: 10)!, gap: 10)
        XCTAssertEqual(below[0], before[0])
        XCTAssertEqual(below[1], g)
        XCTAssertEqual(below[2].minY, before[2].minY + 50)
        XCTAssertEqual(below[2].maxY, before[2].maxY)
    }

    func testANeighbourKeepsItsMinimumLength() {
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let before = OutsideRegions.frames(in: wide, count: 2, gap: 10)
        var f = before[0]
        f.size.width += 800
        let after = OutsideRegions.frames(in: wide, shares: OutsideRegions.shares(resizing: 0, to: f, in: wide, shares: [1, 1], gap: 10)!, gap: 10)
        XCTAssertEqual(after[1].width, 100)
        XCTAssertEqual(after[1].maxX, 990)
    }

    func testOuterEdgesAndTheCrossSizeAreNotShared() {
        let tall = CGRect(x: 0, y: 0, width: 600, height: 1000)
        let before = OutsideRegions.frames(in: tall, count: 2, gap: 10)
        var top = before[0]
        top.origin.y += 40
        top.size.height -= 40
        XCTAssertNil(OutsideRegions.shares(resizing: 0, to: top, in: tall, shares: [1, 1], gap: 10))
        var narrow = before[1]
        narrow.size.width -= 200
        XCTAssertNil(OutsideRegions.shares(resizing: 1, to: narrow, in: tall, shares: [1, 1], gap: 10))
        XCTAssertNil(OutsideRegions.shares(resizing: 0, to: before[0], in: tall, shares: [1], gap: 10))
    }
}
