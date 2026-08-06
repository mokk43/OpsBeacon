# OpsBeacon implementation plan

Status: Revised after the design interview and architecture review on 2026-08-06. This document plans implementation; it does not authorize application-code changes.

The domain language is defined in [`CONTEXT.md`](../CONTEXT.md). Durable trade-offs are recorded in [`docs/adr/`](./adr/). If this plan and those documents disagree, the glossary and accepted ADRs win until the conflict is resolved explicitly.

## 1. Outcome and scope

Build a sandboxed, native macOS menu-bar utility that:

- monitors multiple Log File Sources and Local Push Sources concurrently;
- converts source input into Signals and evaluates explicitly ordered, first-match Rules;
- matches Signals immediately and batches resulting Alerts in one global Collection Window, defaulting to one minute;
- maintains at most one logical, durable Toast, synchronized across all Active Displays;
- retains up to the newest 200 Alert rows until explicit Acknowledgement;
- survives ordinary app restarts without losing log cursor state, Pending Alerts, the Collection Window, or the open Toast;
- provides Settings for Sources, Rules, the Collection Window, launch-at-login, and Toast geometry.

Not in version one:

- macOS Notification Center delivery;
- remote or LAN HTTP access;
- acknowledged Alert history or audit storage;
- multiline log framing;
- arbitrary scripts, JSONPath, or a general Rule expression language;
- message templates;
- cloud sync, accounts, or multi-user configuration;
- a Dock-resident main window.

## 2. Proposed implementation defaults

These choices make the plan concrete but were not all product-level interview decisions. Confirm or revise them before application implementation begins.

1. **Minimum system:** macOS 14.0. This permits native SwiftData persistence and `SMAppService` support.
2. **Language/tooling:** Swift 6 language mode with strict concurrency, built by the current local Xcode 26.3 toolchain.
3. **UI split:** AppKit owns the stable `NSStatusItem` lifecycle and `NSPanel` Toast Copies; SwiftUI supplies Settings and hosted Toast content.
4. **HTTP implementation:** Apple SwiftNIO (`NIOCore`, `NIOPosix`, `NIOHTTP1`, and `NIOFoundationCompat`) is the only third-party package dependency.
5. **Push addressing:** one app-wide configurable loopback port serves `POST /v1/sources/{source-id}/signals`; every Local Push Source owns a generated bearer Push Credential.
6. **Push limits:** accept at most 256 KiB of JSON body, 16 KiB of headers, and 32 concurrent connections app-wide; close idle or incomplete requests after five seconds.
7. **Launch at login:** exposed as an opt-in setting, off by default.
8. **Monitoring Pause:** persists across relaunch, so restarting the app cannot silently resume monitoring.
9. **Rule/settings edits:** affect only Signals received after the edit. An active Collection Window keeps its captured duration and already-matched Alerts.
10. **Source disable/enable:** disabling closes the runtime and discards input while disabled; re-enabling a Log File Source begins at the then-current end of file, while re-enabling a Push Source reopens its listener.
11. **Log safety:** one completed log line is limited to 256 KiB; larger lines are discarded through their newline and create a durable Source Issue.

## 3. Project shape

Create one Xcode project with one application target, unit tests, and UI tests. Keep Modules as internal source folders until a second real production consumer justifies a package or framework seam:

```text
OpsBeacon.xcodeproj
OpsBeacon/
  App/
    OpsBeaconApp.swift
    AppDelegate.swift
    AppEnvironment.swift
  Domain/
    Source.swift
    Signal.swift
    Rule.swift
    Alert.swift
    Severity.swift
    JSONValue.swift
  AlertEngine/
    AlertEngine.swift
    AlertEngineState.swift
    AlertEngineClock.swift
    AlertStore.swift
    RuleMatching.swift
  Sources/
    SourceSupervisor.swift
    SourceRuntime.swift
    LogFile/
      LogFileSourceRuntime.swift
      LogLineFramer.swift
      LogCursor.swift
      SecurityScopedLogAccess.swift
    LocalPush/
      LocalPushHTTPListener.swift
      PushRouteRegistry.swift
      PushSignalDecoder.swift
      HTTPResponse.swift
  Persistence/
    ConfigurationStore.swift
    SwiftDataAlertStore.swift
    SwiftDataConfigurationStore.swift
    SchemaV1.swift
    Records/
  Presentation/
    StatusItem/
      StatusItemController.swift
    Settings/
    Toast/
      ToastPresentationCoordinator.swift
      ToastPanel.swift
      ToastView.swift
      AlertRow.swift
      DisplayGeometry.swift
  Resources/
    Assets.xcassets
    Info.plist
    OpsBeacon.entitlements
OpsBeaconTests/
OpsBeaconUITests/
```

The folders express Module ownership without creating a separate binary target. Tests use `@testable import OpsBeacon`; extract a package only when another production target needs the same Interface. Keep views from talking directly to SwiftData records or Source runtimes.

## 4. Runtime flow and isolation

```text
Log runtime Adapter ─┐
                     ├─> SourceSupervisor ─> AlertEngine actor
HTTP route Adapter ──┘                         │       │
                                              │       └─> AlertStore Interface
                                              │             ├─ SwiftData Adapter
                                              │             └─ in-memory test Adapter
                                              v
                                    AsyncStream<AlertSnapshot>
                                              │
                                              v
                              ToastPresentationCoordinator @MainActor
                                              │
                                              v
                                   one NSPanel per Active Display
```

`AlertEngine` is the deep Module and the main behavioral test surface. Its external Interface remains small:

```swift
func start() async throws -> AlertSnapshot
func applyConfiguration(_ configuration: AlertConfiguration) async throws
func ingest(_ signal: Signal, from sourceID: Source.ID) async throws -> IngestResult
func setMonitoringPaused(_ paused: Bool) async throws
func acknowledgeDisplayed() async throws
func snapshots() -> AsyncStream<AlertSnapshot>
```

Interface guarantees:

- `ingest` returns only after Rule evaluation completes and any matched Pending Alert is durably committed.
- `applyConfiguration` installs one immutable, monotonically revised Source-name/Rule snapshot; after it returns, every later `ingest` uses that revision, while previously matched Alerts remain unchanged.
- `IngestResult` distinguishes accepted-unmatched, accepted-matched, and discarded-during-pause outcomes.
- `AlertEngine` alone owns ordered Rule evaluation, Monitoring Pause, Collection Window timing, overflow accounting, Acknowledgement, recovery, and durable Alert transitions.
- Rule matching and clock handling are private/internal seams exercised through the same Interface; they are not public coordinator Modules.
- `AlertStore` is a real persistence seam because production uses a SwiftData Adapter and tests use an in-memory Adapter. It loads and atomically saves complete engine state without exposing SwiftData records.
- `SourceSupervisor` owns runtime start/stop/reconfiguration and Source health, but never owns pause or Alert semantics.
- Configuration edits are persisted first, then applied to `AlertEngine`, then reconciled by `SourceSupervisor`; Settings reports success only after all three steps complete. A runtime-start failure leaves the configuration durable and creates a Source Issue rather than rolling back silently.
- Every Source runtime awaits `ingest` before submitting its next Signal; it does not create detached, unbounded ingestion tasks.
- `ToastPresentationCoordinator` is `@MainActor` and is the only owner of `NSPanel` instances.
- No file, socket, matching, or persistence work runs on the main actor.

Startup order is fixed: construct Adapters, load persisted configuration, call `AlertEngine.start()` for recovery, apply the latest Alert configuration revision, subscribe presentation to snapshots, then let `SourceSupervisor` reconcile enabled runtimes. Until that sequence completes, the shared HTTP listener returns `503` and log runtimes do not advance cursors.

## 5. Persistent model

Prefer SwiftData behind `AlertStore` and configuration-store Interfaces, but treat crash consistency as a Phase 0 proof gate rather than an assumption. SchemaV1 carries an explicit version; add a migration plan only when a second schema exists. If kill-point tests cannot prove the required atomic transitions, switch the production Adapter to SQLite/GRDB and record that decision before feature work continues.

SwiftData managed objects never cross the persistence Adapter. `AlertEngine` loads and saves immutable domain state, while the Adapter performs one explicit `ModelContext.save()` per transition with autosave disabled.

### SourceRecord

- stable UUID, user-visible name, Source kind, enabled flag, and display order;
- Log configuration: security-scoped bookmark for the containing directory, configured relative file path, last resolved path for display only, file identity, committed byte offset, and any completed-generation recovery metadata;
- Push configuration: a Keychain reference for its Push Credential; the Source UUID is the stable route identifier;
- runtime health timestamps may be ephemeral, but monitoring-loss conditions are durable Source Issues.

### RuleRecord

- stable UUID, owning Source UUID, user-visible name, enabled flag, explicit order, and Severity;
- Log Rule payload: contains/regular-expression mode, pattern, and case sensitivity;
- Push Rule payload: optional exact Signal name plus ordered typed conditions;
- invalid regular expressions or incomplete typed operands block Save in Settings.

### AlertRecord

- stable UUID and monotonic insertion sequence;
- state: `pending` or `displayed`;
- Occurrence Time and receipt time;
- Source UUID plus Source-name snapshot;
- Rule UUID plus Rule-name snapshot;
- Severity and complete original message;
- optional canonical Push attributes for details/copy operations;
- Collection Window identifier.

Snapshot Source and Rule names into the Alert so later edits or deletion cannot rewrite an unacknowledged row.

### RuntimeStateRecord

Singleton containing:

- monitoring paused/running state;
- active window UUID, start time, deadline, or frozen remaining duration;
- separate durable displayed-omitted and pending-omitted Alert counts;
- schema/application state version.

### AppSettingsRecord

- one configurable Local Push listener port;
- Collection Window duration and launch-at-login preference;
- nonsecret application preferences only.

### SourceIssueRecord

- stable UUID, Source UUID, issue kind, safe redacted detail, occurrence time, and resolution state;
- rotation gaps, oversized log lines, revoked authorization, and persistent listener failures are latched across restart;
- clearing an issue records user intent but never claims that missed input was recovered.

### DisplayGeometryRecord

- persistent Core Graphics display UUID;
- last usable display frame;
- Toast Copy origin and size;
- geometry is clamped into the current `visibleFrame` whenever the display layout changes.

### Transaction invariants

Every `AlertEngine` transition is one `AlertStore` transaction:

1. Matching creates a Pending Alert and starts or joins the active Collection Window.
2. Window expiry changes the batch to displayed, merges it with existing displayed rows, retains the newest 200, and transfers the pending-omitted count plus every newly pruned row into the displayed-omitted count.
3. Keep at most the newest 200 Pending Alerts as well; count excess Pending Alerts separately as pending-omitted so a one-minute flood cannot grow storage without bound.
4. Acknowledgement deletes displayed Alerts and resets only the displayed-omitted count; it never touches Pending Alerts or their pending-omitted count.
5. Source/Rule deletion never cascades into Alert deletion.

Keep Push Credentials in Keychain, not SwiftData or logs. Settings can copy or regenerate a credential after an explicit user action but cannot recover an older credential after regeneration.

Disable automatic iCloud/CloudKit sync. Original operational messages remain local to the Mac.

## 6. Domain matching

### Ordered evaluation

- Fetch enabled Rules for the Signal's Source in explicit ascending order.
- Evaluate sequentially and stop at the first match.
- Produce zero or one Alert per Signal.
- Capture Rule name and Severity at match time.

### Log Rule

- One completed UTF-8 line is the complete match subject.
- Decode invalid UTF-8 loss-tolerantly with replacement characters and retain exactly what is displayed.
- `contains` uses locale-independent literal matching.
- `regular expression` uses Foundation regular-expression semantics and is compiled when the Rule is saved.
- Case sensitivity applies to either mode and defaults to case-insensitive.
- The editor runs the same production matcher against user-provided sample text.

### Push Rule

- Exact `name` match is optional.
- Attribute paths use JSON Pointer syntax relative to `attributes`, avoiding ambiguity when object keys contain dots.
- Conditions are AND-combined.
- `exists` succeeds when the member is present, including explicit JSON `null`.
- `equals` and `not equals` compare the same JSON types; a missing path matches neither.
- `contains` accepts string operands and string values only.
- numeric comparison accepts JSON numbers only and compares decimal values without string coercion.
- Any incompatible or missing value makes that condition false.
- A Rule with no name and no conditions matches every Push Signal owned by its Source.

## 7. Log File Source

### File authorization

- Enable App Sandbox, user-selected read-only files, and app-scoped security bookmarks.
- Add a Source by selecting its containing directory once through `NSOpenPanel`, then choose or enter a relative log-file path inside that authorized directory. Reject absolute paths and `..` traversal.
- Store the read-only, directory-scoped security bookmark plus the configured relative path; resolve the bookmark on every launch, refresh stale bookmarks, and bracket access with `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
- If access is revoked or resolution fails, mark the Source as requiring attention and provide a Reauthorize action.

### Initial attachment and line framing

- On first add, record the current file identity and EOF without reading historical bytes.
- Monitor vnode writes off the main actor.
- Buffer bytes after the committed offset and emit only LF-terminated lines; remove the CR in a CRLF terminator.
- Never commit the cursor past an incomplete trailing line, so a restart rereads that fragment safely.
- Cap one line at 256 KiB. Once the cap is exceeded, discard bytes through the terminating newline, advance the cursor, emit no Signal, and latch an oversized-line Source Issue; never match or display truncated content as though it were original.
- Persist cursor progress in bounded batches—for example after each read cycle, not once per byte.

### Restart, rotation, and truncation

- Resume the stored file identity and committed offset after restart.
- While running, keep the old descriptor long enough to drain unread complete lines after rename/replacement, then open the configured path as the new generation from byte zero.
- On truncation of the same generation, reset to byte zero.
- If rotation happened while OpsBeacon was offline, search direct children of the authorized directory for the stored file identity, bounded to 1,000 entries or 250 ms, and drain it when accessible before following the new path. Never scan recursively.
- If the old generation no longer exists, surface a nonfatal monitoring-gap diagnostic and follow the replacement from byte zero; do not pretend the missing bytes were read.
- While paused, continue framing and submit each eligible Signal to `AlertEngine`; its discarded-during-pause result is the single source of truth, after which the cursor advances normally.

### Source status

Expose `starting`, `monitoring`, `paused`, `needsAuthorization`, `fileMissing`, `degradedAfterGap`, and `failed` states with a concise diagnostic in Settings and the status-item summary. Persist monitoring gaps, oversized lines, and revoked access as Source Issues; their current condition may resolve, but the record remains until the user clears it, and restart must never erase it.

## 8. Local Push Source

### Listener

- Use one app-wide SwiftNIO HTTP/1.1 listener, with server channels bound explicitly and separately to `127.0.0.1` and `::1` on the same configured port.
- Never bind wildcard addresses such as `0.0.0.0` or `::`.
- Validate the app-wide port as `1024...65535`; surface an operating-system bind failure as a latched Source Issue on every enabled Local Push Source.
- Enable the App Sandbox incoming-network entitlement.
- Route by stable Local Push Source UUID; disabling a Source disables its route without restarting the listener.
- Start and stop the IPv4/IPv6 channels as one runtime; either address failing marks Local Push monitoring degraded and exposes the exact safe error.
- Bound request admission to 32 connections app-wide. A handler awaits `AlertEngine.ingest` directly and never creates a detached task, so matching and persistence apply backpressure instead of growing an unbounded queue.

### Request contract

Accept only:

```http
POST /v1/sources/{source-id}/signals HTTP/1.1
Content-Type: application/json
Authorization: Bearer {push-credential}
```

Envelope:

```json
{
  "name": "backup.failed",
  "message": "Nightly backup exited with code 1",
  "occurredAt": "2026-08-06T01:02:03Z",
  "attributes": {
    "job": "nightly",
    "exitCode": 1
  }
}
```

Validation:

- top level must be an object;
- the route must identify an enabled Local Push Source and the bearer Push Credential must match that Source using constant-time comparison;
- `name` is required, nonempty, and bounded to 256 Unicode scalar values;
- `message` is optional and bounded to 32 KiB;
- `occurredAt` is optional ISO 8601 with timezone and defaults to receipt time;
- `attributes` is optional and must be an object;
- unknown top-level fields and invalid known-field types are rejected;
- bound total body, header, connection count, and request time before decoding;
- reject a `Host` value that does not name loopback/localhost with the configured port;
- do not enable CORS; this reduces browser-origin access but is not treated as authentication—the Push Credential is the authorization control.

Responses use JSON and never echo the submitted message:

- `202 {"status":"accepted","matched":true|false}` only after Rule evaluation completes and any matched Pending Alert is durably committed;
- `202 {"status":"paused","discarded":true}` after validation during Monitoring Pause;
- `400` invalid JSON/envelope, `401` missing or invalid Push Credential, `404` wrong path or unknown Source, `405` wrong method, `413` too large, `415` wrong media type;
- `503` when admission is saturated, `AlertEngine` is recovering, or the durable store is unavailable; include `Retry-After` without accepting or discarding the Signal;
- close the connection cleanly after the response in version one.

Generate one 32-byte cryptographically random, base64url-encoded Push Credential per Source and store it as a nonsynchronizing generic-password item in Keychain. Settings provides explicit Copy and Regenerate actions plus a copyable `curl` example; regeneration immediately invalidates the previous value. Never place credentials, full submitted bodies, or authorization headers in logs or error responses.

## 9. AlertEngine state machine and clocks

The Collection Window is internal to `AlertEngine`. Inject a clock at the internal seam so the same public Interface is deterministic in tests.

States:

```text
idle
  └─ first matched Alert -> collecting(deadline, pending)

collecting
  ├─ matched Alert -> append pending
  ├─ deadline -> persist/display batch -> idle
  └─ Pause -> frozen(remaining, pending)

frozen
  ├─ matched input -> impossible; monitoring discards before matching
  └─ Resume -> collecting(now + remaining, pending)
```

Restart recovery:

- restore the displayed Toast first;
- restore Monitoring Pause before starting Sources;
- if frozen, keep the window frozen;
- if collecting with a future deadline, schedule only the remaining duration;
- if collecting with an elapsed deadline, atomically display the batch immediately;
- start Source runtimes only after recovery transactions complete.

Changing the configured duration affects the next Collection Window, never one already collecting or frozen.

Use a monotonic `ContinuousClock` deadline while the process is running so manual wall-clock or timezone changes cannot shorten or extend an active window. Persist a wall-clock deadline for relaunch recovery; after restart or wake, an elapsed persisted deadline delivers immediately, while a future deadline is converted into a new monotonic remaining duration. Clamp negative or implausibly large recovered durations to the configured window and latch a diagnostic rather than waiting indefinitely.

## 10. Status item and Settings

### Status item

Create a stable AppKit `NSStatusItem` and `NSMenu`, with `LSUIElement=true` so no ordinary Dock icon or app-switcher entry appears. The status item is application-owned rather than a removable `MenuBarExtra`; closing Settings or all Toast Copies never terminates monitoring.

Status-menu contents:

- status summary: Running/Paused plus healthy/enabled Source counts;
- Pause Monitoring or Resume Monitoring;
- Show Alerts, enabled only when a Toast is open;
- Settings…;
- Quit OpsBeacon.

Use a stable status-item symbol for Running, a paused variant, and an issue badge when any enabled Source has an uncleared Source Issue, even if its current condition has resolved. Severity belongs to Alerts, not global Source health.

### Settings

Use one Settings scene with three sections:

1. **General:** Collection Window duration, one Local Push listener port, launch at login, current monitoring state, and reset-to-default Toast geometry.
2. **Sources:** add Log File or Local Push Source, rename, enable/disable, inspect health and durable Source Issues, authorize a log directory, choose a relative log path, copy endpoint/credential/curl example, regenerate a Push Credential, and delete.
3. **Rules:** select a Source, add/edit/enable/delete Rules, drag to reorder, test a Log Rule, and edit typed Push conditions.

Guardrails:

- Collection Window accepts a bounded duration, proposed as 1 second through 1 hour, default 60 seconds.
- Source names must be nonempty but need not be globally unique; the UI also shows kind and endpoint/path.
- Changing the app-wide Push port restarts both loopback channels atomically; on bind failure, restore the last working port and preserve the error as a Source Issue on every enabled Local Push Source.
- Every Local Push Source has a stable route UUID and independent Push Credential; Source names do not participate in routing or authentication.
- Deleting or disabling a Source requires confirmation when it is currently healthy and active.
- Clearing a resolved Source Issue is explicit and never alters log cursors, Alerts, or overflow counts.
- Displayed/Pending Alerts remain as immutable snapshots after Source or Rule edits.
- Launch at login uses `SMAppService.mainApp.register()` / `unregister()` and reports denied approval with a route to System Settings.

## 11. Toast presentation

### Logical Toast store

`AlertEngine.snapshots()` exposes one immutable view snapshot containing:

- displayed Alert rows ordered oldest to newest;
- omitted count;
- current highest Severity;
- whether newer rows arrived while a copy was scrolled away from the bottom.

`ToastPresentationCoordinator` subscribes after `AlertEngine.start()` recovery completes; it never queries SwiftData or mutates Alert state directly. Appending a batch updates every Toast Copy from the same snapshot. Each copy owns its own scroll position and geometry, not independent Alert state.

### Panel behavior

Create an AppKit `NSPanel` per Active Display and host `ToastView` with `NSHostingView`.

- use accessory-app activation and a nonactivating panel style;
- do not activate or steal keyboard focus when creating or updating a panel;
- permit deliberate mouse/key interaction for scrolling, selection, Copy, moving, resizing, and Acknowledgement;
- join the current Space and participate as a full-screen auxiliary window without switching Spaces;
- hide the standard close/minimize affordances so only Acknowledgement closes the logical Toast;
- start at 520 points wide in the upper-right of `visibleFrame`;
- fit content up to 40% of usable height, then scroll;
- allow user resizing up to 80% of usable width/height and define an implementation-tested minimum;
- clamp restored geometry when resolution, scaling, Dock position, or display layout changes.

The exact window level needed to appear over full-screen apps is a prototype gate, not an assumption: test the lowest safe level that meets the requirement and does not cover system security UI.

### Active Display reconciliation

- Intersect `NSScreen.screens` with active Core Graphics displays.
- Exclude sleeping, inactive, and mirrored-secondary displays; mirrored sets receive one Toast Copy.
- Key geometry by persistent display UUID rather than array order.
- Observe screen-parameter changes and reconcile: create a copy for a newly active display, remove one for a disconnected/sleeping display, and restore/clamp remembered geometry on return.
- Acknowledgement from any copy runs one storage transaction and closes all copies.

### Toast content

- Header: OpsBeacon, visible Alert count, omitted count when nonzero, and the highest Severity using both symbol and color.
- Rows: `Occurrence Time · Source name · original message` on one visual line.
- Today uses local `HH:mm`; older rows use local `yyyy-MM-dd HH:mm`.
- Long text ends with an ellipsis; tooltip and context-menu Copy expose the complete message.
- Rule name and Push attributes appear in accessible details/tooltip/context actions without taking permanent row width.
- Rows are oldest-to-newest; append at bottom.
- Auto-scroll only when already at bottom. Otherwise preserve reading position and expose a New Alerts control.
- Acknowledged is a prominent, accessible button that clears all currently displayed rows and the omitted count, not Pending Alerts.

### Accessibility and appearance

- Use semantic SwiftUI colors, SF Symbols, and text labels; never encode Severity by color alone.
- Supply VoiceOver labels for header status, each row, overflow, New Alerts, and Acknowledgement.
- Support keyboard navigation and Copy after deliberate interaction.
- Respect Reduce Motion, Reduce Transparency, increased contrast, and system text sizing.
- Verify light mode, dark mode, Stage Manager, full-screen apps, menu-bar notch layouts, left/right/bottom Dock positions, and mixed-scale displays.

## 12. Diagnostics and privacy

- Use `Logger`/OSLog categories for lifecycle, source health, matching counts, collection transitions, persistence, HTTP status, and presentation reconciliation.
- Mark paths and producer data private; never log full log lines, Push messages, attributes, bookmarks, or request bodies by default.
- Expose safe Source diagnostics in Settings: state, last successful input time, last match time, and durable redacted Source Issues. The status item shows an unresolved-issue badge without exposing message content.
- Never log or export Push Credentials, bearer headers, Keychain identifiers, or security-scoped bookmark data.
- Do not add analytics, crash upload, or outbound networking in version one.
- Provide a user action to export redacted diagnostics only after a separate product decision; it is not part of this plan's first implementation.

## 13. Implementation phases and acceptance gates

### Phase 0 — scaffold and risk spikes

1. Create the single app target, unit/UI test targets, Swift 6 concurrency settings, macOS 14 deployment target, sandbox entitlements, and SwiftNIO package pin.
2. Prove a stable `NSStatusItem` opens Settings and survives all windows closing without a Dock icon or unintended termination.
3. Prototype one nonactivating `NSPanel` over normal and full-screen apps without focus theft, then two synchronized panels across extended and mirrored displays.
4. Prototype one dual-stack loopback listener on a single port, including sandbox entitlement, route dispatch, Keychain credential retrieval, and atomic port rebinding.
5. Prototype one directory-scoped bookmark that continues to authorize a replaced log file and a renamed rotation generation.
6. Prototype the SwiftData `AlertStore` Adapter with autosave disabled and kill the process after each write step for match, expiry, overflow pruning, Pause, and Acknowledgement.

Gate: do not build feature breadth until status-item lifecycle, overlay behavior, shared listener, directory authorization, and crash-atomic Alert storage are proven. If SwiftData fails the durability gate, select and document the replacement Adapter before Phase 1.

### Phase 1 — first end-to-end tracer bullet

1. Implement the `AlertEngine` Interface with the in-memory `AlertStore` Adapter, a manual clock, ordered first-match `contains` Rules, one Collection Window, and Acknowledgement.
2. Implement one minimal Log runtime that starts at EOF and frames bounded completed lines from an authorized directory.
3. Implement one single-display Toast Copy with original-message rows and the Acknowledged action.
4. Wire the stable status item to Running/Paused, Show Alerts, Settings, and Quit.
5. Drive the real path: appended log line → Signal → first Rule → Pending Alert → Collection expiry → Toast → Acknowledgement.

Gate: the user-visible tracer bullet works through the real `AlertEngine` Interface with no SwiftData, HTTP, rotation recovery, or multi-display behavior. Tests assert only observable engine snapshots and ingestion results.

### Phase 2 — durability and complete Alert semantics

1. Install the proven production `AlertStore` Adapter and SchemaV1; keep the in-memory Adapter for Interface tests.
2. Add regular-expression and complete Push Rule matching, typed conditions, Severity, and sample-testing behavior inside `AlertEngine`.
3. Add pause/freeze/resume, monotonic/wall-clock recovery, the 200 displayed/Pending caps, separate omitted counts, immutable Source/Rule snapshots, and durable Acknowledgement.
4. Persist Source/Rule configuration, Source Issues, Toast geometry, and Monitoring Pause.
5. Run kill-point and randomized restart sequences against the production Adapter.

Gate: process-kill tests prove no duplicate matching, implicit Acknowledgement, split overflow counts, lost Pending Alerts, or indefinite deadlines through the public `AlertEngine` Interface.

### Phase 3 — Log File Source hardening

1. Add cursor persistence, invalid UTF-8 handling, CRLF, partial lines, and the 256 KiB discard-until-newline state.
2. Add live rotation/replacement draining, truncation, bounded offline identity lookup, missing-file recovery, and authorization renewal.
3. Add paused cursor advancement through `AlertEngine.ingest` results.
4. Persist and display oversized-line, rotation-gap, and authorization Source Issues.

Gate: integration tests cover append, chunk boundaries, CRLF, invalid UTF-8, oversize recovery, restart, live/offline rotation, truncation, access revocation, and Pause without rereads or unbounded memory.

### Phase 4 — shared Local Push listener

1. Start one IPv4/IPv6 loopback listener and route stable Source UUIDs on the app-wide port.
2. Add Keychain-backed Push Credentials, constant-time bearer validation, strict host/path/method/media handling, request limits, and redacted responses.
3. Feed requests through `AlertEngine.ingest` without detached tasks; send `202` only after matching and durable commit, and `503` without acceptance when admission or persistence is unavailable.
4. Add paused discard responses, disabled/unknown routes, credential regeneration, atomic port rebinding, graceful shutdown, and Source Issues.

Gate: integration tests prove authentication, valid/invalid responses, durable `202` semantics, bounded backpressure, size/time/connection limits, no wildcard bind, IPv4/IPv6 parity, and no credential/message leakage.

### Phase 5 — complete Settings and status controls

1. Implement General, Sources, Rules, and Source Issues sections.
2. Add log-directory/relative-path configuration, Push route/credential/curl actions, drag ordering, validation, sample tests, status summaries, and destructive confirmations.
3. Wire Pause/Resume, listener-port rebinding, Source enable/disable, issue clearing, geometry reset, and launch-at-login.

Gate: UI tests create both Source kinds, edit/reorder Rules, manage credentials without logging them, persist/relaunch settings, pause/resume, recover authorization, and handle denied login-item approval safely.

### Phase 6 — multi-display Toast completion

1. Complete Toast header, rows, tooltips, Copy, scrolling, overflow, Acknowledgement, and geometry restoration.
2. Reconcile Active Displays and one Toast Copy per display.
3. Synchronize content/Acknowledgement while preserving per-copy scroll and geometry.
4. Handle connect, disconnect, sleep/wake, mirroring, scaling, Spaces, full-screen, Stage Manager, and Dock/menu changes.

Gate: manual and automated geometry tests show no duplicate logical Toast, stranded copy, focus theft, or inconsistent Acknowledgement, and all presentation updates originate from `AlertEngine` snapshots.

### Phase 7 — hardening and release

1. Verify the performance budgets with a 100,000-Signal flood, 200-row rendering, repeated rotations, and many authenticated HTTP connections.
2. Run Thread Sanitizer and Address Sanitizer where compatible.
3. Audit entitlements, Keychain usage, OSLog privacy, dependency licenses, and persisted-data deletion.
4. Add app icon, About information, versioning, signing, notarization, and release archive checks.
5. Update README with installation, directory authorization, Push credentials/examples, Pause semantics, Source Issues, and privacy behavior.

Gate: release build, tests, budgets, accessibility pass, and signed/notarized smoke tests all succeed on the minimum supported macOS and the current macOS.

## 14. Test plan

### AlertEngine Interface tests

Test behavior through `start`, `applyConfiguration`, `ingest`, `setMonitoringPaused`, `acknowledgeDisplayed`, and emitted snapshots. Do not preserve micro-tests for private coordinator-shaped implementation details.

- ordered/disabled Rules and first-match stopping;
- monotonically revised configuration snapshots and the exact edit/ingest ordering boundary;
- contains/regular-expression modes and case sensitivity;
- every Push operator across missing, null, Boolean, string, number, array, and object values;
- accepted-matched, accepted-unmatched, and discarded-during-pause results;
- Collection Window idle/collecting/frozen behavior with a manual clock;
- monotonic timing plus persisted wall-deadline recovery;
- immutable Source/Rule snapshots after configuration edits/deletion;
- Severity aggregation, separate Pending/displayed caps, omitted-count transfer, and Acknowledgement isolation;
- snapshot ordering and no duplicate emissions after restart.

Run the same engine contract suite with both in-memory and production `AlertStore` Adapters where storage behavior is involved.

### Model-based and fault-injection tests

- Generate randomized sequences of ingest, time advance, Pause, Resume, Acknowledgement, Rule reorder/edit, Source deletion, and restart.
- After every command, assert: at most one Alert per Signal, at most 200 Pending and 200 displayed rows, no acknowledged displayed row, no Pending row removed by Acknowledgement, and consistent omitted counts.
- Repeat each durable transition with process termination before and after the Adapter save; relaunch must expose either the complete prior state or complete next state, never a split transition.
- Simulate wall-clock changes, timezone changes, sleep/wake, elapsed deadlines, and implausible recovered deadlines.

### Adapter integration tests

- line framing across arbitrary byte chunks, CRLF, partial lines, invalid UTF-8, and discard-until-newline after 256 KiB;
- real temporary directories/files for append, cursor restart, rotation, bounded offline lookup, truncation, missing files, and persistent Source Issues;
- stale/revoked directory-bookmark error mapping where testable;
- real authenticated loopback HTTP over IPv4 and IPv6 through one listener and multiple Source routes;
- bearer failures, Host/CORS behavior, body/header/connection/time limits, bounded admission, `503` retry semantics, and graceful cancellation;
- prove `202 accepted` is not written until evaluation and any matched Pending Alert commit complete;
- isolated Keychain test items for creation, lookup, regeneration, deletion, and redaction;
- geometry clamping and mirrored-display selection as pure calculations.

### UI and manual tests

- status-item state, persistence after all windows close, explicit Quit, and no ordinary Dock window;
- Settings validation, keyboard navigation, VoiceOver, contrast, and appearance modes;
- one, two, and three extended displays; mirrored displays; hot plug; sleep/wake;
- independent copy movement/resize and geometry restoration;
- full-screen video/app, separate Spaces, and Stage Manager;
- focus remains in the foreground app when Toasts appear/update;
- clicking permits Copy, scroll, move, resize, and global Acknowledgement;
- 200 rows, overflow count, ellipsis/tooltip, preserved scroll position, and New Alerts control.

### Performance budgets

Establish the exact reference Mac and measurement script in Phase 1. These initial release budgets are gates, not informal profiling targets:

- less than 2% average idle CPU over five minutes and less than 150 MiB resident memory with ten idle Log Sources plus the shared listener;
- completed log line to `AlertEngine` ingestion within 250 ms at p95, excluding Collection Window delay;
- authenticated unmatched HTTP response within 100 ms at p95 and matched/durably committed response within 250 ms at p95;
- Collection Window deadline to snapshot within 100 ms at p95 and to all Toast Copies within 250 ms at p95;
- a 100,000-Signal stress run remains bounded to the defined Alert/connection caps, below 250 MiB resident memory, with no main-actor stall over 100 ms;
- no busy polling while files, listener, and Toast are idle.

If a budget is unrealistic on the minimum supported reference Mac, revise it explicitly with measured evidence before release rather than silently waiving it.

### Verification commands

Once the project exists, the normal local proof should include:

```sh
xcodebuild test -project OpsBeacon.xcodeproj -scheme OpsBeacon -destination 'platform=macOS'
xcodebuild analyze -project OpsBeacon.xcodeproj -scheme OpsBeacon -destination 'platform=macOS'
xcodebuild build -project OpsBeacon.xcodeproj -scheme OpsBeacon -configuration Release -destination 'platform=macOS'
```

Also inspect the built app's entitlements and code signature before release.

## 15. ADR traceability

| Decision | Owning Module/Adapter | First phase | Required proof |
|---|---|---:|---|
| [ADR-0001](./adr/0001-use-custom-overlays-for-multidisplay-toasts.md) | Toast presentation Adapter | 0 | focus/full-screen prototype and UI tests |
| [ADR-0002](./adr/0002-use-loopback-http-for-local-push.md) | shared HTTP Adapter | 0/4 | loopback, authentication, routing, and bind tests |
| [ADR-0003](./adr/0003-require-a-stable-push-signal-envelope.md) | Push decoder inside HTTP Adapter | 2/4 | strict envelope contract tests |
| [ADR-0004](./adr/0004-use-ordered-first-match-rule-evaluation.md) | AlertEngine | 1 | Interface-level Rule tests |
| [ADR-0005](./adr/0005-use-one-synchronized-toast-across-displays.md) | Toast presentation Adapter | 0/6 | multi-display synchronization tests |
| [ADR-0006](./adr/0006-batch-alert-presentation-in-collection-windows.md) | AlertEngine | 1/2 | manual-clock and recovery tests |
| [ADR-0007](./adr/0007-persist-unacknowledged-alerts.md) | AlertEngine and AlertStore Adapters | 0/2 | kill-point/restart tests |
| [ADR-0008](./adr/0008-cap-the-toast-at-200-alert-rows.md) | AlertEngine | 1/2 | randomized overflow invariants |
| [ADR-0009](./adr/0009-discard-signals-during-monitoring-pause.md) | AlertEngine and Source Adapters | 1/3/4 | pause/freeze/discard tests |
| [ADR-0010](./adr/0010-centralize-alert-transitions-in-alert-engine.md) | AlertEngine | 1 | all domain behavior tested through its Interface |
| [ADR-0011](./adr/0011-use-a-stable-appkit-status-item.md) | status-item Adapter | 0/1 | lifecycle test after all windows close |
| [ADR-0012](./adr/0012-bound-log-lines-and-latch-source-issues.md) | Log runtime Adapter | 0/3 | bounded-line/gap/issue persistence tests |

## 16. Definition of done

Version one is complete only when:

- every accepted term and ADR is reflected in runtime behavior;
- `AlertEngine` is the only owner of Rule evaluation, Pause, Collection Window, overflow, Acknowledgement, and durable Alert transitions;
- both Source kinds run simultaneously and expose honest health states;
- first-match Rules behave identically in tests and Settings previews;
- Pause discards new Signals and freezes the current Collection Window;
- restart recovery never duplicates or loses a matched Alert within the defined 200-row retention boundary;
- exactly one logical Toast is synchronized across all Active Displays;
- Toast appearance/update never steals focus, but deliberate interaction works;
- Acknowledgement from any display deletes only displayed Alerts and closes every Toast Copy;
- one authenticated loopback listener routes every Local Push Source, applies bounded backpressure, and sends `202` only after evaluation and required durable storage;
- oversized log lines and monitoring gaps cannot exhaust memory or disappear across restart; they remain honest Source Issues;
- the stable status item remains available after Settings and all Toast Copies close;
- all performance budgets are met on a documented minimum-system reference Mac;
- the app is sandboxed, loopback-only, signed, notarized, accessible, and verified on supported macOS versions;
- README and user-facing examples describe the actual shipped contract.

## 17. Primary references

- [AppKit NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [AppKit fullScreenAuxiliary window behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [AppKit canJoinAllSpaces window behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces)
- [AppKit NSPanel becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- [SwiftData ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)
- [SwiftData ModelContext autosaveEnabled](https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled)
- [Swift ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock)
- [Security Keychain services](https://developer.apple.com/documentation/security/keychain-services)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Service Management SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple SwiftNIO](https://github.com/apple/swift-nio)
