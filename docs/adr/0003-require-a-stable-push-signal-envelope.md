# Require a stable Push Signal envelope

The version-one Local Push Source accepts a JSON object with a required non-empty `name` string and optional `message` string, ISO 8601 `occurredAt` timestamp, and `attributes` object; missing `occurredAt` means receipt time, while unknown top-level fields or invalid known fields are rejected. This stable envelope was chosen over arbitrary JSON so producers receive useful validation and Rules have predictable fields; Alert title and severity remain Rule-owned rather than producer-controlled.
