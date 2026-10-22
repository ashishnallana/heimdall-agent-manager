# Heimdall for Codex

Tested with Codex CLI **0.162.0**. This is an observed release, not a claimed minimum.

Install from the repository's dedicated Codex marketplace:

```sh
codex plugin marketplace add /absolute/path/to/repo/extensions
codex plugin add heimdall@heimdall-codex
```

Open `/hooks` in Codex and review the hook commands before trusting them. Installation and enablement do not imply hook trust or an active Heimdall connection. Changed hook definitions require normal review again. Heimdall supplies `HEIMDALL_CTL_BIN`, the local endpoint, and the instance token when launching an agent; outside that environment the hooks print nothing.

For a local marketplace update, update the checkout, then remove/add the plugin to refresh its cached package:

```sh
codex plugin remove heimdall@heimdall-codex
codex plugin add heimdall@heimdall-codex
```

`codex plugin marketplace upgrade <name>` applies to Git marketplaces; the tested local marketplace rejects that command.

The package deliberately uses `.codex-plugin/plugin.json`. In the tested release, adding a portable root `plugin.json` hid all bundled hooks, including with the official `extensions["com.openai"].hooks` shape. Native inventory found all ten hooks only with the compatibility manifest alone. Do not add a root manifest without repeating that release gate. The Claude marketplace is separate and unchanged.

| Signal | Verified boundary |
| --- | --- |
| Sessions/activity | Native startup, clear, resume, fork, prompt, stop, interrupt, session end |
| Tools | Local calls with native use IDs; hosted tools are not covered |
| Children | Native lifecycle, tool, and concurrent permission identity |
| Permissions | Synchronous native requests; allow/deny or no decision |
| File edits | Confirmed successful `apply_patch` operations only |

Bash post callbacks supply stdout without an exit code, including for exit 7. They close calls as **completed, outcome unknown**, without a success badge. Failed patches may omit the post callback; final lifecycle flush closes unfinished calls as interrupted.

Patch creates contain the new file text. Updates/moves provide explicitly partial native snippets without fabricated line offsets. Deletes provide operation metadata because no deleted preimage is available. No file snapshots are read from disk. Shell/MCP changes are not inferred.

Manual compaction emitted pre/post compact callbacks but no `SessionStart(source=compact)` in the observed run. Generic notifications and a native tool-failure event are unavailable. Compaction alone does not imply an activity transition.

Permission timeout, disconnect, cancellation, and no decision retain the native prompt; they never auto-allow. The permission hook budget is 330 seconds over the relay's 300-second maximum. Interrupt and session-end hooks use three seconds.

See [fixture procedure](fixtures/README.md) and [release evidence](fixtures/EVIDENCE.md). Continuous integrated hub/UI validation follows review and integration with the startup branch; local native-to-bridge evidence and hub reducer tests are separate.
