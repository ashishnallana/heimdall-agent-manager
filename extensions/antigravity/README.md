# Heimdall Provider Extension for Google Antigravity

Version **0.1.0**. Provides native, deterministic event interception and interactive control for Google Antigravity (`agy`) agents managed by Heimdall Agent Manager.

Replacing legacy terminal screen-scraping (`source=pane_diff`), this extension normalizes Antigravity's lifecycle hooks into Heimdall's provider-neutral `ham.ext.v1` protocol:

- **Live Activity State**: Real-time status reporting (`active`, `idle`, `waiting_for_user`) driven by `PreInvocation` and `Stop` hooks.
- **Session Tracking**: Precise recording of conversation IDs, model identifiers, workspace roots, and transcript log paths.
- **Tool Lifecycle & Telemetry**: Interception of tool executions (`PreToolUse`, `PostToolUse`) with deterministic step IDs (`step_<stepIdx>`).
- **Subagent Hierarchies**: Tracking asynchronous subagents (`invoke_subagent`, `define_subagent`) and attributing child tool executions to their parent conversations.
- **Unified File Diffs**: Automatic generation of unified diffs for mutating file tools (`write_to_file`, `replace_file_content`), capped at 64KB (`EXT_DIFF_MAX_BYTES`). Non-diffable and binary files are safely skipped.
- **Interactive Permission Approvals**: In `permission_mode: ask`, destructive tool calls are gated in the Heimdall UI via `agent.extension.permission`, allowing users to approve or deny changes from the web interface.

All lifecycle hooks invoke:
```bash
"$HEIMDALL_CTL_BIN" extension hook antigravity
```
which reads Antigravity's camelCase protojson payload from `stdin`, maps it to `ham.ext.v1`, and communicates with the local Heimdall Bridge socket.

---

## Installation

### 1. Standalone / Development Discovery
To load the extension directly from a repository checkout without global installation:

```bash
agy --add-dir <repo>/extensions/antigravity
```

Alternatively, register the plugin in your workspace `.agents/plugins/` or reference it within `.agents/plugins.json`.

### 2. Plugin Installation via CLI
Install the plugin into your Antigravity environment:

```bash
agy plugin install <repo>/extensions/antigravity
```

Verify that the plugin is detected and active:

```bash
agy plugin list
```

Validate the manifest and hook integrity:

```bash
agy plugin validate <repo>/extensions/antigravity
```

### 3. Read-Only Filesystem & Nix Compatibility
In Nix-managed homelabs and developer environments (e.g. NixOS or Home Manager), `~/.gemini/hooks.json` is typically a read-only symlink pointing into the `/nix/store/`.

The Heimdall extension **never** attempts to mutate `~/.gemini/hooks.json` or write to global directories directly. Instead, Heimdall Bridge instances mount the extension per-workspace using `--add-dir extensions/antigravity` or workspace project discovery, guaranteeing zero interference with read-only host configurations.

---

## Behavior Outside Heimdall

The extension is designed with strict **fail-open** semantics and is completely safe to install globally:

1. **Unset Environment**: When Antigravity is run interactively outside Heimdall, `HEIMDALL_CTL_BIN` is unset. Hook processes exit 0 immediately with empty stdout.
2. **Missing Bridge Credentials**: If `HEIMDALL_CTL_BIN` is set but `HEIMDALL_BRIDGE_ENDPOINT` or `HEIMDALL_AGENT_TOKEN` are empty or whitespace, `ham-ctl` exits 0 silently.
3. **No Prompt Pollution**: Non-permission hooks strictly output empty stdout. Non-empty output in Antigravity hook handlers can inject unwanted tokens into the model context.

### Hook Lifecycle & Timeouts

| Hook Event | Timeout | Action | Output / Decision |
|---|---|---|---|
| `PreInvocation` | 10s | Emits `hello`, `session` (phase: start), and `activity` (active) over local Bridge socket (500ms socket timeout). | Empty stdout (`{}`) |
| `PostInvocation` | 10s | Telemetry synchronization. | Empty stdout (`{}`) |
| `PreToolUse` | 330s | Emits `tool.start`. If interactive permission is required, relays request to Bridge (`agent.extension.permission`) with a 300s budget. Allowlisted `ham-ctl` commands are auto-approved locally. | `{"decision": "allow"}` / `{"decision": "deny"}` / fallback `{"decision": "ask"}` |
| `PostToolUse` | 30s | Emits `tool.end`. Generates unified file diffs for `write_to_file` and `replace_file_content`. | Empty stdout (`{}`) |
| `Stop` | 10s | Emits `activity` (idle) and `session` (end). | `{"decision": "stop"}` or `{}` |

---

## Permission Models & Coordination

Heimdall supports two permission modes for Antigravity agents:
- **`permission_mode: auto`**: Tool calls execute without manual intervention.
- **`permission_mode: ask`**: Potentially destructive tools (`run_command`, `write_to_file`, `replace_file_content`) pause and request approval.

### Local Auto-Approval of Coordination Commands
To prevent coordination deadlocks where an agent cannot answer its own blocker, `ham-ctl` command invocations (`chat`, `task`, `lease`, `verify`, `extension`, `agent start-success`) are verified by `is_ham_ctl_command` and **auto-approved locally** at once. These execute immediately without generating Bridge round-trips or UI blockers.

### Bridge Restart Resilience
If the Heimdall Bridge restarts while an agent hook is waiting for approval:
1. The hook retains ownership of the blocker with a persistent `blocker_id` (`blk_<timestamp>_<random>`).
2. Upon connection drop, the hook retries connecting with exponential backoff (250ms to 2000ms).
3. Upon reconnection, it re-registers the **same** blocker ID with its remaining timeout budget.
4. The Bridge restores the blocker in memory without disrupting the user prompt.

### Fallback to Terminal Prompt
The `PreToolUse` hook has a 330-second budget, while the Bridge permission relay is capped at 300 seconds (`PERMISSION_RELAY_TIMEOUT_MS`, customizable via `HEIMDALL_EXT_PERMISSION_TIMEOUT_MS`).

If the user does not respond within 300 seconds, or if the Bridge cannot be reached, the hook cleanly falls back to:
```json
{ "decision": "ask" }
```
This hands control back to Antigravity's native interactive terminal prompt. The agent loop is never permanently hung.

---

## Diagnostics

Verify extension status and connectivity from inside a Heimdall agent terminal:

```bash
# Check provider extension registration, capabilities, and event counters
ham-ctl extension status

# Validate plugin manifest and hook definitions
agy plugin validate extensions/antigravity

# List all imported/installed plugins in the active workspace
agy plugin list
```

---

## Package Layout

```text
extensions/antigravity/
├── plugin.json         # Plugin manifest (name: "heimdall", version: "0.1.0")
├── hooks.json          # Symlink to hooks/hooks.json for Antigravity plugin loader discovery
├── README.md           # Architecture, installation, and operation guide
└── hooks/
    └── hooks.json      # Declarative lifecycle hook definitions mapping events to ham-ctl
```
