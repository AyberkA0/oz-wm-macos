import XCTest
@testable import OzCore

final class LiveRateTests: XCTestCase {
    func testRateDropsAsMemoryFills() {
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.3), 24)
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.5), 24)    // "above" half: not yet
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.6), 18)    // 25% less
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.8), 12)    // 50% less
        XCTAssertEqual(LiveRate.fps(memoryUsed: 0.95), 4)    // 85% less (3.6, rounded)
    }

    func testNeverZero() {
        XCTAssertEqual(LiveRate.fps(memoryUsed: 1, base: 2), 1)
    }
}
