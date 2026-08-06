# Use a stable AppKit status item

OpsBeacon uses an AppKit `NSStatusItem` for its persistent menu-bar control rather than making SwiftUI `MenuBarExtra` the application's primary lifecycle scene. A monitoring utility must not terminate merely because its menu extra is removed, so the stable status item owns menu access while SwiftUI remains responsible for Settings and hosted Toast content, accepting a small amount of AppKit lifecycle code for predictable continuous operation.
