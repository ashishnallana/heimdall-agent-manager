# MCP task offload acceptance

The acceptance harness runs the real native Hub, Bridge, OAuth consent flow,
vault encryption and task engine against a disposable account and database.
With the optional live flags, a real Codex process completes a task and an
external Claude Code process creates another task and retrieves its encrypted
artifact through MCP. Mock OIDC supplies synthetic sign-in only; task execution,
Bridge transport, vault delivery and artifact retrieval are real.

## Prerequisites and execution

Build the Hub and Bridge from the commit under review, using the repository's
native build environment. Supply explicit paths for the native binaries and the
installed native CLI and PTY host. Node must support TypeScript stripping and
`tls.setDefaultCACertificates`; OpenSSL and the UI dependencies must be available.

```bash
HEIMDALL_E2E_HUB_BIN=/absolute/path/ham-hub \
HEIMDALL_E2E_BRIDGE_BIN=/absolute/path/ham-bridge \
HEIMDALL_E2E_CTL_BIN=/absolute/path/ham-ctl \
HEIMDALL_E2E_PTY_HOST_BIN=/absolute/path/ham-pty-host \
node --import ./tests/helpers/vaultEndpointHarness.ts \
  tests/e2e/mcp_control_plane_e2e.ts
```

The default run validates OAuth, scoped discovery, hosted and device artifact
decryption through a real enrolled Bridge, idempotency and ownership denial. It
does not execute a model. To exercise actual model execution, explicitly add:

```bash
export HEIMDALL_E2E_LIVE_RUNTIME=1
export HEIMDALL_E2E_PROVIDER_CODEX_HOME=/absolute/path/to/codex-home
export HEIMDALL_E2E_MODEL=gpt-6.1-sol
export HEIMDALL_E2E_CLAUDE_CLIENT=1
```

The selected Codex home must have an access credential valid for at least ten
minutes. The harness copies it into a private temporary home with its refresh
token removed. It does not copy personal configuration or plugins. Claude Code
uses the operator's existing login and a private, temporary MCP configuration;
hooks, additional settings sources and session persistence are disabled. Model
execution consumes the operator's provider allowance.

The live run creates a durable agent, project, chain and tasks, configures the
fleet, starts the chosen provider and waits for real native lease submission.
Claude must call `tasks.create` and `artifacts.get`; the harness independently
checks the second task is done and its artifact contains the expected marker.
A bounded test barrier queues that second task before native idle shutdown. This
does not establish that arbitrary stopped provider sessions can resume.

An optional `HEIMDALL_E2E_MOVE_MODEL` requests a real native model reconfiguration
and requires its operation to reach completion; acceptance alone is insufficient.
Native reconfiguration creation and advancement acquire the shared SQLite unit
of work. This prevents an unrelated polling or rejected request from rolling
back progress written by the autonomous reconciliation thread. The repository
concurrency regression covers both initial creation and advancement.

## Second physical machine

The optional remote adapter launches a disposable Bridge profile through an
explicit operator CLI and an owned Bridge. It refuses enrollment when a legacy
fixed-name Bridge service exists. It never installs or restarts a production
service. Supply these additional settings:

```bash
export HEIMDALL_E2E_BIND_ADDRESS=<private-IP-reachable-from-second-machine>
export HEIMDALL_E2E_REMOTE_BRIDGE=<owned-production-bridge-id>
export HEIMDALL_E2E_OPERATOR_INSTANCE_ID=<operator-instance-id>
export HEIMDALL_E2E_OPERATOR_CTL_BIN=/absolute/path/to/operator/ham-ctl
export HEIMDALL_E2E_REMOTE_TEST_BINARY=1
```

The current remote adapter verifies the physical hostname is `dawnstar`. Adapt
that explicit assertion when testing another authorized machine. It downloads
only the test Bridge and public CA, verifying SHA-256 pins before enrollment.
All credential-bearing traffic then uses the pinned CA. Pairing and enrollment
progress return through a private random HTTPS callback, without polling shell
logs. The public download endpoints exist only inside this temporary harness.

On NixOS the adapter uses an existing store loader and SQLite library. If the
system libcurl lacks WebSocket support, explicitly set
`HEIMDALL_E2E_REMOTE_LIBCURL` to the tested local libcurl. Its existing Homebrew
library dependencies are copied into a private, hash-pinned test bundle, loaded
only by the disposable Bridge. This is a test compatibility mechanism, not a
release-packaging or deployment solution.

## Evidence and limits

Successful runs print a sanitized `REPORT` JSON line and save `report.json` in
the private test root. It records synthetic resource IDs, physical machine count,
actual model execution and Claude tool use. Those IDs refer to the disposable
Hub and are not production artifact links. Share only the sanitized report and
selected assertion results: never upload provider credentials, MCP configuration,
private keys, full databases, enrollment logs or raw model transcripts.

This test does not claim Claude cloud/browser acceptance, production deployment,
all possible provider/OS combinations, or resolution of the separate vault
security audit. Hosted decryption retains the documented operator-memory trust
boundary. Existing audit and rollout gates remain applicable.
