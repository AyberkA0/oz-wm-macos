import XCTest
@testable import OzCore

final class LiveRateTests: XCTestCase {
    func testRateDropsAsMemoryFills() {
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.3), 30)
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.5), 30)    // "above" half: not yet
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.6), 23)    // 25% less (22.5, rounded)
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.8), 15)    // 50% less
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.95), 5)    // 85% less (4.5, rounded)
    }

    func testExtremesGoDownToOneFrame() {
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.95), 5)
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.97), 1)
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.4, critical: true), 1)
    }

    func testNeverZero() {
        XCTAssertEqual(LiveRate.fps(memoryUsed: 1, base: 2), 1)
    }
}
