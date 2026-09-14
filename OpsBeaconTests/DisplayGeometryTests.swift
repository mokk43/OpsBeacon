import XCTest
@testable import OpsBeacon

final class DisplayGeometryTests: XCTestCase {
    func testPopupIsTopCenteredOnEachDisplay() {
        let screens = [
            CGRect(x: 0, y: 24, width: 1_440, height: 800),
            CGRect(x: -1_920, y: -300, width: 1_920, height: 1_080),
            CGRect(x: 1_440, y: 900, width: 1_280, height: 720),
        ]
        for screen in screens {
            let frame = DisplayGeometryMath.defaultFrame(in: screen)
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertEqual(frame.maxY, screen.maxY - 16)
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testPopupCentersAfterClampingSavedSizeToSmallerScreen() {
        let screen = CGRect(x: -800, y: 24, width: 800, height: 600)
        let frame = DisplayGeometryMath.defaultFrame(in: screen, size: CGSize(width: 1_600, height: 1_200))
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY - 16)
        XCTAssertEqual(frame.size, CGSize(width: 640, height: 480))
    }

    func testClampKeepsToastWithinVisibleFrameAndAtUsableSize() {
        let visible = CGRect(x: 0, y: 24, width: 1_440, height: 800)
        let restored = CGRect(x: 1_300, y: 700, width: 1_000, height: 1_000)

        let clamped = DisplayGeometryMath.clamped(restored, into: visible)

        XCTAssertTrue(visible.contains(clamped))
        XCTAssertLessThanOrEqual(clamped.width, visible.width * 0.8)
        XCTAssertLessThanOrEqual(clamped.height, visible.height * 0.8)
    }
}
