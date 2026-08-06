# Bound log lines and latch Source Issues

OpsBeacon accepts Log Signals up to 256 KiB, discards bytes through the terminating newline for any larger line, and records a durable Source Issue instead of matching truncated content. This intentionally sacrifices an oversized occurrence to bound memory and preserve truthful original-message semantics; rotation gaps, oversized lines, revoked access, and comparable monitoring-loss conditions remain visible until explicitly cleared after their current condition resolves rather than disappearing on restart.
