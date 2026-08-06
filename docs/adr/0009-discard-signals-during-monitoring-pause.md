# Discard Signals during Monitoring Pause

While monitoring is paused, Log File Sources continue advancing and Local Push Sources accept valid input with an explicit paused response, but incoming Signals are discarded before Rule evaluation and never replayed after resume; any active Collection Window freezes with its remaining duration, while the existing Toast stays visible and acknowledgeable. This makes Pause a predictable quiet boundary and prevents backlog floods, at the irreversible cost of intentionally missing conditions that occur during the pause.
