import XCTest

final class OpsBeaconUITests: XCTestCase {
    func testAppLaunchesAsAnAccessoryApplication() throws {
        let application = XCUIApplication()
        application.launch()
        XCTAssertNotEqual(application.state, .notRunning)
        application.terminate()
    }
}
