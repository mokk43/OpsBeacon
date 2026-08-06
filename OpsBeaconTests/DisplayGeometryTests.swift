import XCTest
@testable import OpsBeacon

final class DisplayGeometryTests: XCTestCase {
    func testClampKeepsToastWithinVisibleFrameAndAtUsableSize() {
        let visible = CGRect(x: 0, y: 24, width: 1_440, height: 800)
        let restored = CGRect(x: 1_300, y: 700, width: 1_000, height: 1_000)

        let clamped = DisplayGeometryMath.clamped(restored, into: visible)

        XCTAssertTrue(visible.contains(clamped))
        XCTAssertLessThanOrEqual(clamped.width, visible.width * 0.8)
        XCTAssertLessThanOrEqual(clamped.height, visible.height * 0.8)
    }
}
