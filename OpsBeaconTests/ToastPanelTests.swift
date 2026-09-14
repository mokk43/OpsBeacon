import AppKit
import SwiftUI
import XCTest
@testable import OpsBeacon

@MainActor
final class ToastPanelTests: XCTestCase {
    func testHoverTransfersKeyboardFocusWithoutClicking() {
        let application = NSApplication.shared
        let previous = ToastPanel(frame: NSRect(x: 600, y: 100, width: 400, height: 200))
        let panel = ToastPanel(frame: NSRect(x: 100, y: 100, width: 400, height: 200))
        previous.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            previous.orderOut(nil)
        }
        XCTAssertTrue(application.keyWindow === previous)
        panel.pointerHoverChanged(true)
        XCTAssertTrue(application.keyWindow === panel, "Hover must route keyboard events to the alert without a click")
    }

    func testHoverTrackingWorksBeforeThePanelIsKey() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPSBEACON_TEST_MOUSE_HOVER"] == "1",
            "Opt-in interaction test moves and restores the mouse pointer"
        )
        _ = NSApplication.shared
        let panel = ToastPanel(frame: NSRect(x: 100, y: 100, width: 400, height: 200))
        let view = NSHostingView(rootView: ToastView(
            snapshot: AlertSnapshot(state: .init()),
            acknowledge: {},
            hoverChanged: { [weak panel] in panel?.pointerHoverChanged($0) }
        ))
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        func trackingAreas(in view: NSView) -> [NSTrackingArea] {
            view.updateTrackingAreas()
            return view.trackingAreas + view.subviews.flatMap { trackingAreas(in: $0) }
        }
        let areas = trackingAreas(in: view)
        XCTAssertTrue(areas.contains {
            $0.options.contains([.activeAlways, .mouseEnteredAndExited])
        }, "Hover must be tracked while another app has focus; options: \(areas.map { $0.options.rawValue })")
        let originalMouse = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens[0].frame.maxY
        func moveMouse(to point: NSPoint) {
            XCTAssertEqual(CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screenHeight - point.y)), .success)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        defer { moveMouse(to: originalMouse) }
        moveMouse(to: NSPoint(x: panel.frame.maxX + 30, y: panel.frame.midY))
        moveMouse(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        XCTAssertTrue(NSApp.keyWindow === panel, "Moving inside must focus the alert without a click")
    }

    func testEnterAcknowledgesOnlyInsideVisiblePanel() {
        _ = NSApplication.shared
        let panel = ToastPanel(frame: NSRect(x: 100, y: 100, width: 400, height: 200))
        var acknowledgements = 0
        panel.acknowledge = { acknowledgements += 1 }
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let inside = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let outside = NSPoint(x: panel.frame.maxX + 10, y: panel.frame.maxY + 10)

        XCTAssertTrue(panel.acknowledgeIfEligible(key(36), mouseLocation: inside))
        XCTAssertTrue(panel.acknowledgeIfEligible(key(76), mouseLocation: inside))
        XCTAssertEqual(acknowledgements, 2)
        XCTAssertFalse(panel.acknowledgeIfEligible(key(36), mouseLocation: outside))
        XCTAssertFalse(panel.acknowledgeIfEligible(key(0), mouseLocation: inside))
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            XCTAssertFalse(panel.acknowledgeIfEligible(key(36, modifiers: modifier), mouseLocation: inside))
        }
        XCTAssertTrue(panel.acknowledgeIfEligible(key(36, repeating: true), mouseLocation: inside))
        XCTAssertEqual(acknowledgements, 2)

        panel.orderOut(nil)
        XCTAssertFalse(panel.acknowledgeIfEligible(key(36), mouseLocation: inside))
        XCTAssertEqual(acknowledgements, 2)
    }

    private func key(
        _ code: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        repeating: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: repeating, keyCode: code
        )!
    }
}
