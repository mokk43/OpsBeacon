import AppKit
import XCTest
@testable import OpsBeacon

@MainActor
final class ToastAvailabilityObserverTests: XCTestCase {
    func testRefreshesPresentationWhenSessionBecomesActiveOrScreensWake() {
        let applicationNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        var refreshCount = 0
        let observer = ToastAvailabilityObserver(
            applicationNotificationCenter: applicationNotifications,
            workspaceNotificationCenter: workspaceNotifications
        ) {
            refreshCount += 1
        }

        workspaceNotifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(refreshCount, 3)
        withExtendedLifetime(observer) {}
    }
}
