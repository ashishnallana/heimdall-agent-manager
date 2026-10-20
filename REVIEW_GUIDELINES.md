# Review Guidelines for Heimdall AI Manager POC

Use this guide when reviewing changes in this project. The goal is to preserve the architecture while keeping the POC moving quickly.

## Project Purpose

This project prototypes a local agent coordination system:

- `ham-daemon`: local daemon/control plane
- `ham-wrapper`: launches an interactive agent in tmux and connects it to daemon
- `ham-ctl`: CLI for daemon inspection/control
- `ham-test-agent`: synthetic test/load agent for message flow validation

Core principle:

```text
Actual messages move through RPC + MessageProvider.
WebSocket is metadata/event notification only.
```

Never send actual message bodies over WS.

## Current Identity Model

Primary public identity:

```text
agent_instance_id = agent_class@suffix
```

Examples:

```text
coder-agent@project-1
coder-agent@default
```

Rules:

- If user provides `coder-agent`, wrapper should normalize it to `coder-agent@default`.
- `agent_class` is the part before `@`.
- `agent_instance_id` is the full normalized identity.
- `conversation_id` is mapped from `agent_instance_id`, e.g. `conv_coder-agent_project-1`.
- Do not reintroduce public `client_id` unless project direction changes.

Current validation intentionally supports:

```text
letters, numbers, dash in each part
class@suffix
```

So `coder-agent@project-1` is valid.

## Review Checklist

### 1. Build

Always run:

```bash
cd /Users/tanmayvijay/heimdall-ai-manager
nix build .#ham-daemon .#ham-wrapper .#ham-ctl .#ham-test-agent
```

If `ham-test-agent` does not exist in the branch/session yet, build the first three.

### 2. Canonical RPC Actions Only

RPC action strings must be canonical lowercase snake_case only.

Allowed currently:

```text
send_message
fetch_messages
```

Reject variants like:

```text
Send_Message
SendMessage
Fetch_Messages
FetchMessages
```

Look for helpers like:

```odin
action == "send_message" || action == "SendMessage"
```

and flag them.

### 3. WS Must Be Metadata-Only

WS events may include:

- event type
- conversation ID
- message ID
- pending count
- read timestamp
- agent instance IDs

WS events must not include:

- message body
- payload
- actual content

Good WS event shape:

```json
{
  "type": "message_event",
  "event": "messages_available",
  "conversation_id": "conv_coder-agent_project-2",
  "pending_count": 1
}
```

Read receipt event:

```json
{
  "type": "message_event",
  "event": "messages_read",
  "conversation_id": "conv_coder-agent_project-2",
  "message_id": "msg_1",
  "read_by_agent_instance_id": "coder-agent@project-2",
  "read_unix_ms": 123456789
}
```

### 4. Actual Messages Only Through Provider/RPC

Actual message bodies should flow through:

```text
/agent-rpc send_message -> MessageProvider store
/agent-rpc fetch_messages -> MessageProvider fetch
```

Review that direct WS send paths do not include bodies.

### 5. Read Semantics

Current desired behavior:

```text
fetch_messages by target agent == message read
```

Wrapper receiving WS notification is **not** read.

Provider currently auto-marks target messages read during `fetch_messages`. Daemon sends read receipt events to original sender.

Watch for duplicate read receipts. Normal `fetch_messages` should default:

```json
"include_read": false
```

Repeated normal fetches should not emit duplicate read receipts.

### 6. Duplicate Agent Instance Policy

Duplicate active `agent_instance_id` should be rejected.

Desired behavior:

```text
/register X
  if X does not exist: register
  if X exists and active: reject 409 active_duplicate
  if X exists but stale/dead: replace old entry, preserve conversation_id
```

Current liveness heuristic should consider:

- active WS send succeeds
- heartbeat is recent

Not WS send success alone.

Wrapper should register before launching tmux. If registration fails, it should not create/reuse tmux resources.

### 7. Server Structure

`src/daemon/server.odin` should stay lean.

Expected split:

```text
src/daemon/server.odin       run server, accept loop, route top-level requests
src/daemon/http.odin         request/response helpers
src/daemon/json.odin         JSON extraction/building helpers
src/daemon/ws.odin           WS handshake/frame helpers
src/daemon/lifecycle.odin    register/heartbeat handlers
src/daemon/agent_rpc.odin    RPC action dispatch
```

If `server.odin` starts accumulating message/provider/WS formatting logic again, flag it.

### 8. Message Bus Direction

Planned architecture is in `message-bus-plan.md`.

Desired future flow:

```text
agent_rpc -> message_service -> provider -> message_bus -> ws_events/plugins
```

If reviewing message bus work, ensure:

- provider remains storage/fetch abstraction
- WS event generation happens from events/service, not directly from provider
- plugin/event hooks can be added later
- actual message bodies are internal only and never serialized over WS

### 9. Thread Safety

Daemon handles clients in threads.

Known POC limitation:

- registry global state is not thread-safe
- in-memory provider global state is not thread-safe

At minimum, TODO comments should exist. Do not treat this as production-safe.

For larger testing, expect races until locks are added.

### 10. JSON Parser Limitations

Current JSON parsing is string-search based and not robust.

Important consequence:

- escaped strings are not correctly unescaped
- arbitrary bodies containing quotes/backslashes/braces may break parsing/logging

For `ham-test-agent`, prefer generated message bodies that avoid JSON-special chars until proper JSON parsing exists.

Good test body format:

```text
from=coder-agent@a;to=coder-agent@b;seq=1;ts=123;payload=xxxx
```

Avoid newlines/quotes/backslashes for load-test byte accounting.

## Smoke Tests

### Basic daemon/wrapper list

```bash
ham-daemon --config ./config.toml
ham-wrapper --config ./config.toml coder-agent@project-1
ham-ctl --config ./config.toml list
```

Expected:

```text
agent_instance_id = coder-agent@project-1
agent_class = coder-agent
conversation_id = conv_coder-agent_project-1
```

### Message flow

Run two wrappers:

```text
coder-agent@project-1
coder-agent@project-2
```

Send:

```bash
curl -s -X POST http://127.0.0.1:49322/agent-rpc \
  -d '{"agent_token":"agent_coder-agent@project-1","action":"send_message","target_agent_instance_id":"coder-agent@project-2","payload":"hello"}'
```

Fetch as target:

```bash
curl -s -X POST http://127.0.0.1:49322/agent-rpc \
  -d '{"agent_token":"agent_coder-agent@project-2","action":"fetch_messages","conversation_id":"conv_coder-agent_project-2","include_read":false}'
```

Expected:

- target receives `messages_available` WS event
- fetch returns actual message body
- sender receives `messages_read` WS event

### Test agent smoke

After `ham-test-agent` exists:

- register/start two agents
- run both test agents targeting each other
- inspect:

```text
/tmp/ham-test/stats/*.stats.json
/tmp/ham-test/logs/*.incoming.jsonl
```

Expected:

- sent and received counts increase
- byte accounting should be roughly consistent
- no send/fetch errors in normal run

## Common Problems To Flag

- Actual message body included in WS notification.
- RPC accepts non-canonical action variants.
- Wrapper launches tmux before daemon registration succeeds.
- Duplicate agent instance blocks forever after wrapper crash.
- Read receipt emitted when wrapper receives notification instead of agent fetch.
- Duplicate read receipts on repeated fetch.
- Test-agent byte counts differ due to JSON escaping/newlines.
- Provider sends WS events directly.
- `server.odin` becomes monolithic again.
