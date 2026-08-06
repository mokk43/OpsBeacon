# Use loopback HTTP for local push

OpsBeacon runs one app-wide HTTP listener bound only to loopback interfaces (`127.0.0.1` and `::1`), with each Local Push Source exposed at `POST /v1/sources/{source-id}/signals` and protected by its own generated bearer Push Credential. One listener avoids per-Source socket and port management, HTTP provides explicit success and error responses, and authentication prevents unrelated local processes from submitting Signals merely because they can reach loopback; changing this integration contract later would require coordinated producer changes.
