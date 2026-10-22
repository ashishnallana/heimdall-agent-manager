# Heimdall plugin for Claude Code

Version 0.1.0. Gives Heimdall-managed Claude Code agents live, exact status in
Heimdall instead of terminal screen-scraping:

- **Activity**: working / idle / waiting for you (`UserPromptSubmit`, `Stop`, `Notification`).
- **Session**: the current Claude session id and transcript (`SessionStart`, `SessionEnd`, also across `/clear`).
- **Tools and subagents**: every tool call (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`) and every subagent's lifetime (`SubagentStart`, `SubagentStop`), with tool calls attributed to the subagent that made them.
- **File edits**: a unified diff for each `Edit` / `MultiEdit` / `Write`, capped at 64KB. Binary files are skipped.
- **Permissions**: `PermissionRequest` is shown in Heimdall so you can allow or deny it there. The terminal prompt stays up the whole time, and whichever answer comes first wins.

The plugin is only hook configuration. Every hook runs
`"$HEIMDALL_CTL_BIN" extension hook claude`, which maps Claude's hook JSON to the
provider-neutral `ham.ext.v1` contract and sends it to the local Heimdall Bridge.

## Install

From a checkout of this repository:

```bash
claude plugin marketplace add <repo>/extensions
claude plugin install heimdall@heimdall
```

Check that it is installed:

```bash
claude plugin list --json      # contains "id": "heimdall@heimdall", "enabled": true
```

To try it for one session without installing it:
`claude --plugin-dir <repo>/extensions/claude-code`.

Update after pulling a new version: `claude plugin marketplace update heimdall`, then
`claude plugin update heimdall@heimdall`. Remove it with `claude plugin uninstall heimdall@heimdall`.

## Behaviour outside Heimdall

It is safe to install globally. When Claude Code is not launched by a Heimdall
Bridge, `HEIMDALL_CTL_BIN` is unset and each hook exits 0 at once with no output. If
the variable is set but the Bridge credentials (`HEIMDALL_BRIDGE_ENDPOINT`,
`HEIMDALL_AGENT_TOKEN`) are missing, `ham-ctl` also exits 0 silently.

Hooks never block Claude:

| Hook | Behaviour |
| --- | --- |
| All except `PermissionRequest` | One Bridge round trip with a 500ms socket timeout. Prints nothing. Always exits 0. Hook timeout 10s. |
| `PermissionRequest` | Waits for a decision from Heimdall for up to 300s. Prints Claude's allow/deny JSON. Prints nothing when there is no decision (timeout, answered in the terminal, agent stopped), so the terminal prompt decides. If the Bridge restarts during the wait, the hook reconnects and re-registers the same blocker, so the prompt stays visible in Heimdall. Nothing is stored: prompts live in memory as agent blockers. Hook timeout 330s, which is longer than the wait. |

Set `HEIMDALL_EXT_PERMISSION_TIMEOUT_MS` to shorten the permission wait. Values above 300000 are clamped to 300000.

`PermissionRequest` does not fire in `bypassPermissions` mode
(`--dangerously-skip-permissions`). Agents need Heimdall's per-agent
"Require permission approvals" setting (`permission_mode: ask`) to get approval cards.

## Diagnostics

Inside a Heimdall-launched agent:

```bash
ham-ctl extension status   # provider, version, capabilities, event counters, activity source
```

## Layout

```
extensions/
  .claude-plugin/marketplace.json   marketplace "heimdall"
  claude-code/
    .claude-plugin/plugin.json      plugin "heimdall" 0.1.0
    hooks/hooks.json                every hook → ham-ctl extension hook claude
```

The Claude-specific mapping is in `src/ctl/extension/claude.odin`, with fixture
tests in `src/ctl/extension/claude_adapter_test.odin`.
