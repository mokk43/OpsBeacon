# Use custom overlays for multi-display toasts

OpsBeacon renders Toasts as custom overlay windows rather than macOS Notification Center notifications. Custom overlays provide deterministic placement on every Active Display and never steal keyboard focus when they appear or update, while deliberate user interaction makes their controls usable; in exchange, OpsBeacon owns presentation, dismissal, accessibility, and window lifecycle instead of inheriting system-managed notification behavior.
