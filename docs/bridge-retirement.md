# Bridge retirement and Hub traffic

The bridge parks its automatic Hub traffic when it receives an authoritative
`bridge_sunset_pending` or `bridge_credential_revoked` response. This applies during
WebSocket admission, on an established session, on session renewal, and to typed
HTTP refusals. A final refresh-token authentication refusal also parks traffic.
Access-token expiry alone remains refreshable and does not mean revocation.

## State transitions

| State | Automatic Hub traffic | Recovery |
| --- | --- | --- |
| Active | Normal runtime, heartbeat, refresh and reconnect | Normal transient failures retry |
| Temporary sunset detected | Stopped; both credential files retained | Explicit local activation after rollback |
| Final revocation detected | Stopped; re-enrollment required | Successful enrollment |
| Restart with a pause marker | Parks before enrollment recovery or any runtime networking | Same recovery as above |

The outbound fence is monotonic for the process. A final notice upgrades a temporary
pause; a delayed temporary notice or successful refresh cannot downgrade it. The
token-free, atomically written `<canonical-config>.hub-paused-v1` marker records the Hub,
bridge id and whether the retirement is final. Unreadable/corrupt markers fail closed.
Final revocation also records the existing needs-reenrollment marker for local status.
Successful enrollment clears the pause only after committing the new enrollment.

The runtime stops before draining queues or sending another heartbeat in the
iteration that receives retirement. Every text/binary WebSocket writer checks the
fence under the connection's send mutex, including direct background writers. All
bridge HTTP calls use the guarded Hub transport; refresh, scheduler and search
workers stop, and later HTTP requests return locally with `Aborted` and
`may_have_sent=false`. Update downloads also check the fence before admission.
PTY writers are stopped/joined before the runtime owner closes its WebSocket.
Proxy/tunnel readers exit on their existing timeout wake and close their own local
sockets. No other thread closes those descriptors.

Local agents/shell jobs are not killed merely because Hub traffic is paused.
Local process activity is distinct from authorization to contact the Hub.

## Resuming after rollback

Rollback restores the old bridge's server-side credentials and quota state, but
does **not** automatically reactivate a bridge that already detected its sunset.
There is no status polling or reconnect probe while parked. On that old machine:

1. Confirm the replacement enrollment was cancelled or rolled back.
2. Stop the bridge service using the same config.
3. Clear the temporary pause locally:

   ```bash
   ham-bridge recovery resume-sunset --config /path/to/config.toml
   ```

4. Start the bridge service using that config.

`resume-sunset` takes the config and Hub/bridge scope locks, performs no network
I/O, and refuses a missing, mismatched, corrupt or final pause. It does not clear
the current process's in-memory fence: a fresh process is required. Starting too
early simply receives another suspension and parks again. Final revocation uses
the normal explicit `ham-bridge enroll --hub <url> --config <path>` flow instead.

Explicit operator operations such as enrollment and `--probe-hub` run as separate
commands and intentionally initiate network activity; this pause governs the
automatic runtime, not arbitrary programs on the machine.

## Hub behavior and limits

Revocation still atomically invalidates the bridge/token authority. Sunset keeps
its durable rollback receipt until replacement enrollment commits or is cancelled.
The production connection closer sends the typed reason under the writer lock,
then shuts down the socket; its reader owns the eventual close. The same typed
reason is returned if an offline bridge later attempts admission with stale
credentials. Session revalidation catches revocation outside the local Hub
process, normally within 60 seconds. Credentials are rejected on fresh requests.

The guarantee starts at **detection and outbound admission**, not at the instant
an offline machine is revoked remotely. A disconnected bridge cannot learn about
remote revocation without receiving a response: its first connection/hello or
refresh attempt is unavoidable. A dropped retirement notice is recovered through
the next authenticated admission/refresh response. Transient network errors and
token expiry alone do not prove revocation and retain normal retry behavior.

HTTP requests, connection attempts and transport writes admitted before the fence
was set may finish, including an in-flight TLS/WebSocket control response. Socket
shutdown/cleanup and TCP acknowledgements are transport activity. The Hub cannot
prevent arbitrary packets from another program or an older/malicious client.
Marker persistence requires writable local state: if its write fails, the current
process remains fenced and logs the failure, but a crash may require detection
again on restart. No credentials are logged or included in the pause marker.

Older installed bridges do not understand the new HTTP cause. The pending-sunset
HTTP error deliberately retains its retriable envelope so those clients preserve
recoverable credentials; deploy the updated bridge for traffic quiescence.
