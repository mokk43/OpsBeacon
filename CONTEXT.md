# OpsBeacon

OpsBeacon monitors local operational signals and brings noteworthy conditions to the user's attention without becoming their primary workspace.

## Language

**Menu Bar Utility**:
The continuously available form of OpsBeacon, with menu controls for status, pause or resume, Settings, and Quit, and no ordinary Dock window.
_Avoid_: Main app, dashboard app

**Monitoring Pause**:
A user-selected state in which Sources continue advancing or accepting input but do not offer incoming Signals to Rules. Inputs received during the pause are permanently ignored, the active Collection Window freezes, and resuming never creates a backlog.
_Avoid_: Snooze, deferred monitoring, source shutdown

**Active Display**:
A connected, awake, non-mirrored display eligible to present an alert. Mirrored displays count as a single presentation target; sleeping and disconnected displays do not count.
_Avoid_: Active screen, monitor

**Toast**:
A single logical, durable presentation of unacknowledged Alerts, capped at the newest 200 rows with a count of earlier omitted Alerts. It has one synchronized copy per Active Display and continues receiving Alerts until Acknowledgement.
_Avoid_: Dialog, toast stack, transient notification, Notification Center notification

**Toast Copy**:
The display-specific presentation of the one Toast. Copies share Alert content and Acknowledgement while retaining independent geometry and reading position.
_Avoid_: Independent toast, dialog window

**Acknowledgement**:
The user's explicit confirmation in any displayed copy that closes the Toast on every Active Display and permanently deletes its displayed Alerts and overflow count from OpsBeacon. Alerts still pending in a Collection Window remain unacknowledged and must be displayed when that window ends; the original Sources, not OpsBeacon, remain the records of truth.
_Avoid_: Automatic dismissal, timeout

**Pending Alert**:
A matched Alert durably buffered inside the current Collection Window but not yet displayed in a Toast. The window retains at most the newest 200 Pending Alerts with a separate omitted count; retained Alerts cannot be acknowledged, discarded by restart, or rematched.
_Avoid_: Queued event, hidden toast row

**Collection Window**:
The configurable one-shot interval, defaulting to one minute, started by the first matched Alert and used to buffer later matched Alerts into one display batch. It freezes during Monitoring Pause and survives restart without losing or rematching Pending Alerts.
_Avoid_: Toast lifetime, dismissal timeout, aggregation window

**Source**:
An independently configured and enabled origin of operational input monitored by OpsBeacon. Multiple Sources may run simultaneously.
_Avoid_: Input, feed, event source

**Source Issue**:
A latched operational problem in a Source that caused or may have caused monitoring loss or degraded input handling. Its current condition may resolve, but its record remains visible until explicitly cleared by the user.
_Avoid_: Alert, transient error, log message

**Log File Source**:
A Source that observes records appended to one configured local log file after the Source is first added; existing contents at first configuration are excluded, but later records remain eligible across restarts. On rotation or replacement it completes unread old records before starting the new file at its beginning; after truncation, the new beginning is fresh without rereading consumed records.
_Avoid_: File watcher, log input

**Log Signal**:
A Signal formed from one completed, newline-delimited UTF-8 log line within the accepted size limit. A trailing partial line is not a Signal until its terminating newline arrives, while an oversized line becomes a Source Issue instead of a Signal.
_Avoid_: Log event, log block, multiline event

**Local Push Source**:
A Source represented by an authenticated route on OpsBeacon's single HTTP listener, available only to software running on the same Mac.
_Avoid_: Webhook, JSON server, port listener

**Push Credential**:
A randomly generated secret belonging to one Local Push Source and required from producers that submit Push Signals. Regenerating it invalidates the previous credential.
_Avoid_: User password, shared app secret

**Push Signal**:
A Signal received through a Local Push Source that identifies an occurrence by name and may describe its message, time, and producer-specific attributes. A Push Signal never defines how an Alert is presented.
_Avoid_: Arbitrary JSON, webhook payload, push event

**Signal**:
A discrete operational observation emitted by a Source and offered to Rules for evaluation. A Signal does not by itself request user attention.
_Avoid_: Event, input record, notification

**Rule**:
A user-configured condition owned by exactly one Source and evaluated in its user-controlled order among that Source's Rules. Disabled Rules are skipped and evaluation stops at the first match, so one Signal produces at most one Alert.
_Avoid_: Condition, matcher, filter

**Log Rule**:
A Rule that matches a Log Signal using either text containment or a regular expression, with explicit case sensitivity. Each Log Rule has one matcher.
_Avoid_: Log filter, regex rule

**Push Rule**:
A Rule that may match an exact Push Signal name and an AND-combined set of typed conditions over the Signal's message or attribute paths. Omitting both the name and conditions matches every Push Signal from the owning Source.
_Avoid_: Expression, script, JSONPath filter

**Alert**:
A record produced when a Rule matches a Signal and user attention is warranted, retaining its Occurrence Time, Source name, Rule-owned Severity, and original message for one-line display in a Toast. For a Log Signal the message is the decoded line without its newline; for a Push Signal it is `message`, falling back to `name` when absent.
_Avoid_: Signal, event, notification, toast

**Severity**:
A Rule-owned level of user attention—Info, Warning, or Critical. New Rules default to Warning.
_Avoid_: Priority, Signal severity, color

**Occurrence Time**:
The time associated with an Alert: receipt time for a Log Signal, and `occurredAt` for a Push Signal, falling back to receipt time when absent.
_Avoid_: Display time, toast time, match time
