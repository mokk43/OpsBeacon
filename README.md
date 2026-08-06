# OpsBeacon
A native macOS menu-bar utility that batches operational Signals into one durable, synchronized Toast across active displays.

## Project status

OpsBeacon is a Swift 6/macOS 14 application project. Open [`OpsBeacon.xcodeproj`](./OpsBeacon.xcodeproj) in Xcode 26.3 or later to build the signed, sandboxed app, run the unit/UI targets, and create archives. The companion Swift package keeps the fast contract suite runnable from the command line:

```sh
swift test
swift run OpsBeaconApp
```

Both project files pin SwiftNIO to `2.84.0`. The package command builds the same source tree for fast local verification; the Xcode application target is the release artifact and applies `OpsBeacon.entitlements` plus the accessory-app `Info.plist`.

The application runs as an accessory menu-bar utility—quitting it is explicit from the status menu. Its Alert state uses SwiftData when available; configuration, source metadata, and display geometry are kept in Application Support. Push Credentials are held only in Keychain.

## Local Push contract

Each enabled Local Push Source accepts a single authenticated loopback route:

```text
POST /v1/sources/{source-id}/signals
Authorization: Bearer {push-credential}
Content-Type: application/json
```

The request body is a stable JSON envelope with `name`, optional `message`, optional timezone-qualified `occurredAt`, and optional object `attributes`. A `202` response is returned only after rule evaluation and persistence complete; paused monitoring returns an explicit discarded response. OpsBeacon binds only `127.0.0.1` and `::1`.

## Monitoring behavior

- Log sources start at EOF and only emit complete newline-delimited records. Oversized lines are discarded to their next newline and become a Source Issue.
- Monitoring Pause discards incoming Signals and freezes, rather than restarts, an existing Collection Window.
- The AlertEngine preserves Pending and displayed Alerts across ordinary restarts, keeps at most 200 of each, and requires explicit Acknowledgement to clear displayed rows.

## Design documents

- [Domain language](./CONTEXT.md)
- [Detailed implementation plan](./docs/implementation-plan.md)
- [Architectural decisions](./docs/adr/)
