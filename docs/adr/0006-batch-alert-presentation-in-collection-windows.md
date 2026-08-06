# Batch Alert presentation in Collection Windows

OpsBeacon matches each Signal immediately, then buffers resulting Alerts in a global one-shot Collection Window started by the first match and defaulting to one minute; at expiry, the batch is appended to the one open Toast or opens it if necessary, and the next matched Alert starts a new window. This deliberately trades up to one configured window of presentation latency for batched, low-churn Toast updates while ensuring each Signal uses the Rule configuration active at arrival.
