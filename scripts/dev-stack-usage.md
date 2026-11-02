# Heimdall Dev Stack — Usage Reference

> **Living document.** When you discover something new, fix something wrong, or add a workflow, edit this file. Remove sections that become stale. Add sections as new parts of the stack are exercised. Date significant entries so it is clear when a section was last verified.
>
> Last verified: 2026-10-08 — REQ-IMPL-7 end-to-end verification of the device flow (added §10d: headless enrollment with no browser, the 20-second proactive-refresh observation, the `CLOSE-WAIT` false-negative on revocation, cross-bridge isolation plus where the `bridge_auth_denied` audit lines land, and the legacy-credential message proven over the wire; added §13 rows for the BRE literal-`|` sweep, the stronger "a text sweep cannot prove a behaviour is untested" rule, the compile-time token TTL, the misleading post-revocation WS message, and `ham-ctl shell` failing on the agent's own vault). Previously 2026-10-07 — four concurrent streams: REQ-IMPL-1 bridge credential work (added §1a isolated ports / throwaway DB and §1b the nix-excludes-untracked-files trap), REQ-IMPL-2 bridge device-grant enrollment (corrected the §1 toolchain pin, added the `-lsqlite3` link step, recorded the parallel-runner flake and the `tprintf` brace trap in §13), and REQ-IMPL-3 expiring credentials + refresh (added §10a, corrected the §1/§12/§13 "2026-07a is a version" error — it is a derivation NAME, the binary reports `dev-2026-09` — refined the §13 flake row with the first-error triage rule and a cause count of two, and recorded the no-counts/no-line-numbers-in-comments sweep from REQ-IMPL-1a), and REQ-IMPL-5 approval screen + fragment-key vault delivery (added §10b the device-grant APPROVAL smoke recipe, and §13 rows for the `odin test src/bridge` abort, the `tests/*.odin` run-vs-test trap, and the duplicate-`serve` / self-matching-`pkill` traps).

---

## 0. How this document is used

This doc is a **running reference**, not a tutorial frozen at one point in time. The workflow:

1. You try something with the dev stack, hit a snag, or discover a non-obvious detail.
2. You add it here (or correct a wrong section) **before moving on**.
3. Future you (or another agent) reads this before touching the stack instead of rediscovering things from scratch.

Conventions:
- `PROXY` = dev-proxy URL, default `http://127.0.0.1:8080`. All user-facing API calls go here (auto-injects auth as user `tanmay`).
- `HUB` = hub URL, default `http://127.0.0.1:8081`. Usually you don't call it directly; use the proxy.
- `$BRIDGE_ID` / `$AGENT_ID` / etc = IDs returned by previous calls; substitute real values.
- All `curl` calls assume the proxy is running and authed as the default user.

---

## 1. Starting / stopping the stack

```bash
# One-time: build all nix binaries (result-hub, result-bridge, result-ctl, result-wrapper, result-devproxy)
scripts/dev-stack.sh build

# Start hub + dev-proxy + bridge (repairs bridge config automatically)
scripts/dev-stack.sh start

# Check what is running
scripts/dev-stack.sh status

# Stop local stack (does NOT touch the mundus/production bridge)
scripts/dev-stack.sh stop
```

**If the bridge reports `bridge is offline` after a hub.db reset** (token mismatch):
```bash
scripts/dev-stack.sh enroll    # mints a new bridge token for the current hub.db
scripts/dev-stack.sh start     # restarts with the fresh token
```

**Building without nix on PATH (agent / CI environment):**

**Prefer the dev shell**, which hands you the compiler the flake actually pins, so this
section cannot rot again:
```bash
nix develop -c odin build src/hub -collection:odin_test=src -out:/tmp/ham-hub
```

If `nix` is not on PATH at all, fall back to a direct store path. **This is a
known-fragile workaround** — a store path can be garbage-collected, which is exactly what
happened to the previous pin here:
```bash
# Verified 2026-10-07. This is THE toolchain the flake pins.
# NAME vs VERSION, and do not be alarmed by the mismatch: the nix DERIVATION is named
# `odin-dev-2026-07a`, while the binary inside it reports `odin version dev-2026-09`.
# One toolchain, two labels. `odin version` disagreeing with the store path is EXPECTED
# and is not evidence you are on the wrong compiler -- the store path is the pin.
ODIN=/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/bin/odin
$ODIN check src/hub -collection:odin_test=src          # clean
$ODIN build src/hub    -collection:odin_test=src -out:/tmp/ham-hub
$ODIN build src/bridge -collection:odin_test=src -out:/tmp/ham-bridge
$ODIN build src/wrapper -collection:odin_test=src -out:/tmp/ham-wrapper
```

**Linking the hub needs libsqlite3 on `LIBRARY_PATH`** when nix is not providing it, or
`odin build`/`odin test` fails at the link step with `cannot find -lsqlite3` (a LINK error,
not a compile error — the code is fine):
```bash
export LIBRARY_PATH=/nix/store/7a0nx1a0rdc5s07vxrsdhplqnzncl5z9-sqlite-3.53.3/lib:$LIBRARY_PATH
```

**Do NOT use the 2026-05 build, and ignore the old `.Haiku` warning.** Verified
2026-10-07: the previously pinned `odin-dev-2026-05` store path **no longer exists**, and
on a 2026-05 compiler the tree fails in `src/hub/service/push/webpush_encoding.odin:52`,
where `base64.decode` is called with the 4-argument signature only this toolchain's core
library has — that claim is still true of the pinned binary. The `.Haiku` enum error that
motivated the old advice does not reproduce on it; `odin check src/hub` is clean. If you
see a `.Haiku` error, you are on an older compiler.

**`odin version` says `dev-2026-09`, and that is the right compiler.** Verified
2026-10-07:

```console
$ nix develop . --command bash -c 'which odin; odin version'
/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/bin/odin
odin version dev-2026-09
```

`2026-07a` is a **derivation name**, not a version string. Everything this doc and this
chain's evidence says about "2026-07a" refers to exactly this binary. Pin and compare on
the **store path**; a `odin version` mismatch is not a finding.

**Starting the stack manually (no nix):**
```bash
# Use the pre-built result-* symlinks OR the /tmp/ham-* binaries above.
# Users authenticate ONLY with OIDC. Locally that is the mock provider (DEV ONLY,
# see tools/mock-oidc/README.md):
python3 tools/mock-oidc/mock_oidc.py --port 8090 --username tanmay &
eval "$(python3 tools/mock-oidc/mock_oidc.py --port 8090 --ui-origin http://127.0.0.1:8080 --print-env | grep -v '^#' | sed 's/^/export /')"
# Hub:
result-hub/bin/ham-hub \
  --listen 127.0.0.1:8081 --db hub.db \
  --migrations-dir src/hub/repository/sqlite/migrations \
  --ui-origin http://127.0.0.1:8080

# Dev-proxy (forwards the hub session cookie; adds login_hint=<selected user> to
# the sign-in redirect; /api/v1/* -> hub). Sign in at
# http://127.0.0.1:8080/api/v1/auth/login, or from scripts:
#   . scripts/lib/hub-oidc-dev.sh; SESSION=$(hub_oidc_login http://127.0.0.1:8080 tanmay)
result-devproxy/bin/ham-dev-proxy \
  --listen 127.0.0.1:8080 --hub-url http://127.0.0.1:8081 --default-user tanmay

# Bridge (after enroll):
result-bridge/bin/ham-bridge \
  --hub http://127.0.0.1:8081 \
  --bridge-token "$(cat .run-logs/bridge/bridge-token)" \
  --bind-host 127.0.0.1 --port 49327 \
  --local-endpoint-port 49328 \
  --local-run-dir /tmp/heimdall-bridge-dev
```

---

## 1a. Isolated ports and a throwaway DB — READ BEFORE `start` (verified 2026-10-07)

**The defaults in section 1 do not work on this host, and one of them is destructive.** Run the stack like this instead:

```bash
HAM_DEV_HUB_ADDR=127.0.0.1:8191 \
HAM_DEV_PROXY_ADDR=127.0.0.1:8190 \
HAM_DEV_HUB_DB=/tmp/ham-isolated/hub.db \
HAM_DEV_BRIDGE_RUN_DIR=/tmp/ham-isolated/bridge-run \
scripts/dev-stack.sh start
```
Then `PROXY=http://127.0.0.1:8190` and `HUB=http://127.0.0.1:8191` for every call in the sections below.

### Why: `HAM_DEV_HUB_DB` is the important one

`dev-stack.sh:35` defaults `HUB_DB` to **`$ROOT/hub.db` — the repository's own database**, and `start` runs migrations against whatever it is given. Starting the stack with the default therefore **migrates and mutates the live repo `hub.db`**, which is not a dev artifact. Always point `HAM_DEV_HUB_DB` at a throwaway path. Deleting that file is how you get a clean slate; never delete `./hub.db` for that purpose.

### Why: the default ports are already taken on this host

`:8080` (proxy) and `:8081` (hub) are both bound in normal operation, and `:8081` may be the hub your own agent session is talking to. Alongside them run a QA stack (`:8110`/`:8111`/`:8112`, bridge `:49423`) and the production mundus bridge (`:49323`/`:49324`). Check before you pick:

```bash
ss -ltnp | grep -E '8080|8081|8110|8111|8190|8191|4932|4942'
```
`start` fails loudly with `Address_In_Use` rather than silently misbehaving (`dev-stack.sh:180-190`), so a crash here means pick another port — but note the stack's *bridge* ports (`49327`/`49328`) are free by default and need no override.

**Stopping is safe for the other stacks.** `stop` kills by pidfile first, and its fallback pattern matches on `$HUB_ADDR`, so it cannot reach the QA bridge (`--hub http://127.0.0.1:8112`) or the production bridge (`--hub https://hub.mundus.in`). Verify with `ps -eo pid,args | grep ham-bridge` if you are about to run `stop` on a shared host.

## 1b. `nix build` SILENTLY EXCLUDES YOUR NEW FILES (verified 2026-10-07)

**If you have added a new `.odin` file, `scripts/dev-stack.sh build` does not build your change.**

`build()` runs `nix build "$ROOT#ham-hub"`, and a flake takes its source from **git-tracked files only**. A new file is untracked (`git status` shows `??`), so nix copies the tree *without* it. You then get either a confusing compile error about an undeclared name that is plainly defined in your editor, or — worse — a binary that silently predates your work, and any evidence you collect from the stack is meaningless.

**The tell is the path in the error.** A sandbox copy, not your checkout:
```
/build/9c83al8vqb03rxsjr7ydra2q6nl5qw40-source/src/hub/service/bridge/bridge_service.odin(394:7)
  Error: Undeclared name: verify_credential
```
If the failing path starts `/build/<hash>-source/`, the compiler is reading nix's copy and the file it cannot see is one you have not `git add`ed.

(Note: this repo **is** a git repo even though some project metadata records `VCS: none`.)

Two ways out:

```bash
# A. Build from the working tree with odin directly (no flake, no git involvement).
nix develop . --command bash -c '
  odin build src/hub       -collection:odin_test=src -out:/tmp/ham-isolated/ham-hub
  odin build src/dev_proxy -collection:odin_test=src -out:/tmp/ham-isolated/ham-dev-proxy
  odin build src/bridge    -collection:odin_test=src -out:/tmp/ham-isolated/ham-bridge'
# then run those binaries with the manual recipe in section 1.

# B. Make the files visible to the flake without committing them.
git add -N src/path/to/new_file.odin    # intent-to-add; stages no content
```
Option A is the safer default: it needs no git state change at all, and it is what the "no nix" recipe in section 1 is for. Prefer it whenever you are verifying your own uncommitted work.

> **WHILE A GIT FREEZE IS IN FORCE, OPTION B IS NOT AVAILABLE AND OPTION A IS THE ONLY ROUTE.**
> `git add -N` is a git write. During the freeze on this chain that made `nix build` —
> and therefore `dev-stack.sh build` and `start` — unable to build the tree at all,
> because several of the chain's files were untracked. It failed with three errors
> that all look like broken code and are purely nix's missing files:
> `Undeclared name: issue_bridge_token_pair`, `Failed to #load … 057_bridge_tokens.sql`,
> and `'bridge_refresh_handler' is not declared by 'http'`.
>
> So when you are asked to prove "`dev-stack.sh start` brings up a working stack",
> be precise about what you actually proved: the FLOW can be verified with option A
> binaries end-to-end, while `dev-stack.sh start` itself cannot run the current tree
> until the freeze lifts and the new files are tracked. Say which one you did.

---

## 1c. Four traps when you script the stack yourself (verified 2026-10-07, REQ-IMPL-4)

Found while driving a full browser-approval enrollment end to end with the manual recipe. All four cost a
run each.

**1. There is no `/api/v1/auth/whoami`. Readiness is `GET /api/v1/me`.** And readiness must require an
actual **HTTP 200**: the dev-proxy is up and answering *before* the hub finishes migrating, and it answers
**502 `hub unavailable`** in the meantime. A wait loop of the shape `curl -s -o /dev/null $PROXY/... && break`
succeeds on that 502 and hands the next command a hub that is not there yet. Use:

```bash
for _ in $(seq 1 90); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' $PROXY/api/v1/me)" == "200" ]] && break; sleep 1
done
```

**2. `sqlite3` is not installed on this host.** Use python, which is:

```bash
python3 -c "import sqlite3,sys; con=sqlite3.connect('/tmp/x/hub.db'); \
  [print(r) for r in con.execute('SELECT bridge_id,label,machine_hostname FROM bridges')]"
```

**3. A copied source tree needs `tools/`, not just `src/`.**
`src/bridge/bridge_telemetry.odin` does `#load("../../tools/telemetry/telegraf.conf.template")`, so
`cp -r src /tmp/elsewhere` then `odin test src/bridge` fails with *"Failed to `#load` file"* and nothing to
do with your change. Copy both:
```bash
cp -r <repo>/src <repo>/tools /tmp/elsewhere/
```

**4. Do not let a script `rm -f $S/*.log` when its own stdout is redirected into that directory.** The
redirect target is unlinked while the shell still holds the fd, so the run appears to produce nothing at all
and the log is unrecoverable. Write the transcript outside the directory the script cleans.

### `odin test src/bridge` is NOT a green suite, and it is NOT DETERMINISTIC

**Corrected 2026-10-07 after a second agent could not reproduce the stable picture first written here.
Do not treat any single run of this suite as a signal.** Across two agents and ten-plus full runs:

- **A swinging set of 6-9 pre-existing failures on an unmodified tree.** The names seen:
  `bt_memory_decouple_materialize_run_dir`, three `fs_vault_*`,
  `test_inbound_local_agent_call_refreshes_liveness` (a **Segmentation_Fault**),
  `test_pty_stream_emit_frame_plaintext_when_vault_unconfigured`, and two `test_shell_pty_input_decrypts_*`.
  Individual runs produced 6, 8 and 9 failures from that pool. They are vault/pty/shell tests that depend
  on ambient vault state.
- **An intermittent abort**: `free(): invalid pointer`, exit 134, after the per-test reports but *before*
  the summary line, so the run yields no result at all. **It is intermittent, NOT determined by your
  working directory** — an earlier version of this section claimed moving to `/tmp` avoided it; the second
  agent reproduced it from `/tmp` three times in five runs. Believing the cwd claim is actively harmful:
  you would attribute an abort to your own change.

A segfaulting test, a failure set that swings run to run, and an intermittent `free(): invalid pointer`
all in the same vault/pty area look like **one memory-lifetime fault**, not eight independent ones. Tracked
as `iss_18dc54a73787b582`.

**So how do you get a signal at all?** Not from one run, and never from a count:

1. **Run your own tests by name** — `-define:ODIN_TEST_NAMES=main.a,main.b` — which is deterministic and is
   the only thing that tells you about *your* change.
2. **For the suite, run it several times** and compare the failure NAMES against the pool above. A name
   outside that pool is yours; a smaller or larger subset of it is not news.
3. `-define:ODIN_TEST_THREADS=1` reduces but does not eliminate the abort.
4. Run from a copied tree (with `tools/` **and** `scripts/`, per trap 3) only to avoid touching the repo —
   not as an abort workaround, because it is not one.

**Ports used by REQ-IMPL-4's harness:** `8195` (proxy) / `8196` (hub), bridge `49527`/`49528`. Taken
elsewhere: `8080-8082`, `8088-8091`, `8096`, `8110-8112`, `8190-8193`, `8200`, `49323-49324`, `49423-49424`.

---

## 2. Authentication

All user-facing calls go through the dev-proxy (`http://127.0.0.1:8080`) which injects auth as user `tanmay`. No token header needed.

```bash
# Verify auth / get your user
curl -s http://127.0.0.1:8080/api/v1/me | python3 -m json.tool
```

Bridge calls (enrolling, direct hub bridge routes) use a bridge token:
```bash
BRIDGE_TOKEN=$(cat .run-logs/bridge/bridge-token)
curl -s -H "Authorization: Bearer $BRIDGE_TOKEN" http://127.0.0.1:8081/api/v1/...
```

---

## 3. Agents

### 3.1 Create an agent

```bash
PROXY=http://127.0.0.1:8080

# Minimal (no template, no instructions)
curl -s -X POST $PROXY/api/v1/agents \
  -H 'Content-Type: application/json' \
  -d '{"name":"My Agent","provider":"claude"}' | python3 -m json.tool

# With template + own instructions
curl -s -X POST $PROXY/api/v1/agents \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"My Agent\",\"template_id\":\"$TMPL_ID\",\"instructions\":\"Prefer small diffs.\",\"provider\":\"claude\"}"
```

**Fields:** `name` (required), `provider` (`claude`/`codex`/…), `tier` (`smart`/`fast`), `template_id`, `instructions`.

**Note:** `provider` on the agent is a default hint; the actual provider used at launch time is what the instance gets.

### 3.2 Update an agent

```bash
curl -s -X PATCH $PROXY/api/v1/agents/$AGENT_ID \
  -H 'Content-Type: application/json' \
  -d '{"template_id":"tmpl_...", "instructions":"updated"}'
```

### 3.3 List agents

```bash
curl -s $PROXY/api/v1/agents | python3 -c "import sys,json;[print(a['agent_id'],a['name']) for a in json.load(sys.stdin)['data']]"
```

---

## 4. Templates (agent personas)

Templates carry `persona` + `instructions` that are injected into every agent's bootstrap `AGENTS.md` that uses the template (via the BT-2a identity variable flow: `{template_persona}` / `{template_instructions}` in the single template).

### 4.1 Create a template

```bash
curl -s -X POST $PROXY/api/v1/templates \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "systems-engineer",
    "description": "Meticulous Odin-style engineer",
    "persona": "You are a meticulous systems engineer named Odin.",
    "instructions": "Follow the house style. Write tests before code. Prefer small, reviewed diffs."
  }' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['template_id'])"
```

### 4.2 List / update / delete templates

```bash
curl -s $PROXY/api/v1/templates | python3 -m json.tool
curl -s -X PATCH $PROXY/api/v1/templates/$TMPL_ID \
  -H 'Content-Type: application/json' -d '{"persona":"updated persona"}'
curl -s -X DELETE $PROXY/api/v1/templates/$TMPL_ID
```

**Important:** Templates are seeded by users/agents via the API — the daemon does NOT seed them. Template persona/instructions survive daemon removal (BT-6). Agents reference templates by `template_id`; the hub fetches them at manifest-render time via `content_get_template`.

---

## 5. Projects

```bash
# Create
curl -s -X POST $PROXY/api/v1/projects \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Heimdall",
    "default_path": "~/heimdall-hub-rewrite",
    "repo_url": "git@github.com:tanmayv/heimdall-agent-manager.git",
    "vcs_kind": "git",
    "description": "Enterprise multi-agent orchestrator."
  }' | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['project_id'])"

# ⚠️ Field is `default_path` not `path` — `path` is silently ignored (learned 2026-09-03)

# List
curl -s $PROXY/api/v1/projects | python3 -c "import sys,json;[print(p['project_id'],p['name']) for p in json.load(sys.stdin)['data']]"
```

---

## 6. Launching agent instances

An **agent instance** = one running agent process (a specific agent, on a specific bridge, optionally in a chain + project).

```bash
# Basic launch (worker, no chain, no project)
curl -s -X POST $PROXY/api/v1/agent-instances \
  -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"$AGENT_ID\",\"bridge_id\":\"$BRIDGE_ID\",\"provider\":\"claude\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['agent_instance_id'])"

# Launch in a chain + project (role is passed but coordinator must be set explicitly via chain members)
curl -s -X POST $PROXY/api/v1/agent-instances \
  -H 'Content-Type: application/json' \
  -d "{
    \"agent_id\":\"$AGENT_ID\",
    \"bridge_id\":\"$BRIDGE_ID\",
    \"project_id\":\"$PROJ_ID\",
    \"chain_id\":\"$CHAIN_ID\",
    \"provider\":\"claude\"
  }" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['agent_instance_id'])"
```

**Accepted fields:** `agent_id` (required), `bridge_id` (required), `provider`, `tier`, `project_id`, `chain_id`.

**Note on `role`:** The `role` field is NOT accepted in `create_agent_instance_handler` (`instance_input_from_body` in `agent_handlers.odin` does not extract it). Role is determined by the chain's `coordinator_agent_instance_id` at manifest render time. To make an instance the coordinator, set it via the chain member route AFTER launch (see §7.3).

### 6.1 Stop / restart an instance

```bash
curl -s -X POST $PROXY/api/v1/agent-instances/$INST_ID/stop   -H 'Content-Type: application/json' -d '{}'
curl -s -X POST $PROXY/api/v1/agent-instances/$INST_ID/restart -H 'Content-Type: application/json' -d '{}'
```

### 6.2 List running instances

```bash
curl -s $PROXY/api/v1/agent-instances | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
for i in d: print(i['agent_instance_id'], i['runtime_status'], i.get('chain_id',''))
"
```

---

## 7. Task chains

### 7.1 Create a chain

```bash
curl -s -X POST $PROXY/api/v1/task-chains \
  -H 'Content-Type: application/json' \
  -d '{"title":"My work","description":"# Goal\n\nDo the thing.\n"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['chain_id'])"
```

### 7.2 Publish a chain (makes it visible to agents)

```bash
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/publish \
  -H 'Content-Type: application/json' -d '{}'
```

### 7.3 Set a chain coordinator (add a member)

The coordinator line in `AGENTS.md` (`Coordinator: you (coordinator)` vs `Coordinator: <instance_id>`) is driven by `chain.coordinator_agent_instance_id`. To set it:

```bash
# Add an agent instance as coordinator
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/members \
  -H 'Content-Type: application/json' \
  -d "{\"agent_instance_id\":\"$COORD_INST_ID\",\"role\":\"coordinator\"}"

# Add a worker
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/members \
  -H 'Content-Type: application/json' \
  -d "{\"agent_instance_id\":\"$WORKER_INST_ID\",\"role\":\"worker\"}"
```

**⚠️ Learned 2026-09-03:** adding a member requires `agent_instance_id` (not `agent_id`). The instance must already be launched. `add_chain_member` requires the instance ID.

### 7.4 Create tasks

```bash
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks \
  -H 'Content-Type: application/json' \
  -d "{
    \"title\": \"Implement foo\",
    \"description\": \"Do REQ-1.\",
    \"assignee_agent_instance_id\": \"$WORKER_INST_ID\"
  }" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['task_id'])"

# Publish the task (makes it visible to agents)
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/publish \
  -H 'Content-Type: application/json' -d '{}'
```

### 7.5 Change task status

```bash
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/status \
  -H 'Content-Type: application/json' \
  -d '{"status":"in_progress"}'
# statuses: queued | assigned | in_progress | in_validation | completed | cancelled
```

### 7.6 Add comments, vote, nudge

```bash
# Comment
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/comments \
  -H 'Content-Type: application/json' -d '{"body":"Work started."}'

# Vote (reviewer only)
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/vote \
  -H 'Content-Type: application/json' -d '{"result":"lgtm","comment":"Looks good."}'

# Nudge
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/nudge \
  -H 'Content-Type: application/json' -d '{}'
```

### 7.7 List tasks in a chain

```bash
curl -s "$PROXY/api/v1/task-chains/$CHAIN_ID/tasks" | python3 -c "
import sys,json; tasks=json.load(sys.stdin)['data']
for t in tasks: print(t['task_id'], t['status'], t['title'][:50])
"
```

---

## 8. Reading bootstrapped content (AGENTS.md / skills)

After an agent instance is launched, the bridge materializes its bootstrap files. The wrapper (running as a tmux subprocess of the bridge) fetches the fileset from the bridge and writes it to the instance run dir.

### 8.1 Locate the run dir

Default bridge run dir is `/tmp/heimdall-bridge-local` (production) or whatever `--local-run-dir` was passed. Instance run dirs land at:

```
<bridge-run-dir>/instances/<agent_instance_id>/
```

```bash
INST_RUN=/tmp/heimdall-bridge-local/instances/$INST_ID
# or for local dev stack:
INST_RUN=/tmp/hbt5-bridge-run/instances/$INST_ID   # if started with custom local-run-dir

ls $INST_RUN
# CLAUDE.md (or AGENTS.md for non-claude)  — the rendered bootstrap doc
# .pi/skills/<slug>/SKILL.md               — static skill files
# bin/ham-ctl                             — the ctl shim
# heimdall-bootstrap-manifest.json         — bridge-emitted manifest listing managed files
# .heimdall-wrapper-placed                 — wrapper-owned stale-prune record (added BT-4)
```

### 8.2 Read AGENTS.md / CLAUDE.md

```bash
cat $INST_RUN/CLAUDE.md   # claude profile
cat $INST_RUN/AGENTS.md   # other profiles
```

**New output format (single-template engine, post-BT-2a):**
```
# Agent bootstrap
Agent: <name>
Instance: <inst_id>
Task chain: <title> (<chain_id>)
Coordinator: you (coordinator)  ← or <coord_inst_id> for workers

## Agent Identity & Instructions
### Persona
<template.persona>
### Instructions
<template.instructions>
<agent.instructions>

## Project
...
## You are the COORDINATOR / WORKER / REVIEWER ...  ← role block
## Working with tasks (REQUIRED)
...
## Heimdall CLI        ← appended by bridge, always present
```

**Differences from the old fragment-concatenation model:**
- No `## Applicable Memories` section (memories are fetched separately).
- `### Persona` and `### Instructions` sub-headings always present (stray empty headings OK per design).
- `{{#is_reviewer}}` role block is new.
- Static skills no longer role-gated (all agents get the same set).

### 8.3 Inspect the bridge bootstrap cache

The bridge caches all blobs (template, variable values, skill files) by sha256 hash under:
```
<bridge-data-dir>/bootstrap/blobs/<hash>
```

```bash
# The manifest JSON includes all hashes; the template hash is the sha256 of bootstrap_agents.md:
python3 -c "
import json; d=json.load(open('$INST_RUN/heimdall-bootstrap-manifest.json'))
print('managed:', [f['relative_path'] for f in d['managed_files']])
"
```

### 8.4 Fetch the bootstrap manifest JSON from the hub

The hub serves the agent-keyed manifest at:
```
GET /api/v1/bridge/agents/<agent_id>/bootstrap-manifest?role=<role>&provider=<provider>&project=<project_id>
```

```bash
BRIDGE_TOKEN=$(cat .run-logs/bridge/bridge-token)
curl -s -H "Authorization: Bearer $BRIDGE_TOKEN" \
  "http://127.0.0.1:8081/api/v1/bridge/agents/$AGENT_ID/bootstrap-manifest?role=coordinator&provider=claude&project=$PROJ_ID" \
  | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
print('version:',d.get('version',''))
print('template hash:',d.get('template',{}).get('hash',''))
print('variables:',[v['name'] for v in d.get('variables',[])])
print('skills:',[s['name'] for s in d.get('skills',[])])
"
```

---

## 9. Memories

```bash
# Create a memory (fact type, project-scoped)
curl -s -X POST $PROXY/api/v1/memories \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"fact\",\"title\":\"Key fact\",\"body\":\"Always cite file:line.\",\"project_id\":\"$PROJ_ID\"}"

# List memories
curl -s $PROXY/api/v1/memories | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
for m in d: print(m['memory_id'], m['type'], m['status'], m['title'])
"

# Approve / activate a pending memory
curl -s -X POST $PROXY/api/v1/memories/$MEM_ID/activate \
  -H 'Content-Type: application/json' -d '{}'
```

---

## 10. Bridge enrollment (adding a new bridge) — BROWSER-APPROVED, and it is the ONLY way (REQ-IMPL-6)

> **The one-time-token flow in this section is DELETED.** `POST /api/v1/bridge-enrollments`,
> `GET`/`DELETE` on it, and `POST /api/v1/bridges/enroll` all return **404** now. So do
> `ham-bridge enroll --hub ... --enrollment-token ...` and `heimdall enroll <hbe_...>`,
> which exit non-zero and print the new form. There is no enrollment token any more:
> nothing secret is carried to the machine, because approval happens in a browser.
>
> **If you are following an older runbook and getting 404s on `/api/v1/bridge-enrollments`,
> this is why.** Nothing is broken.

### The easy way: let `dev-stack.sh` do it

```bash
scripts/dev-stack.sh enroll
```

This drives the real device flow end to end and needs **no browser**. It starts
`ham-bridge enroll --hub http://$PROXY --headless`, reads the user code the bridge prints,
and POSTs the approval itself through the dev-proxy — which authenticates every request as
the local user, so that is a genuine authenticated approval through the production
endpoint, not a test bypass. It writes:

- `.run-logs/bridge/bridge-token` — the **expiring** `hba_` access token (1h)
- `.run-logs/bridge/bridge-token.refresh` — the `hbf_` refresh token (30d, single-use)

### By hand, if you want to watch each step

```bash
# 1. The bridge asks for a code. NO auth, NO hub url, NO secret.
#    --hub points directly at the Hub API origin; the Hub returns the browser origin.
result-bridge/bin/ham-bridge enroll \
  --hub http://127.0.0.1:8081 --headless \
  --bridge-token-file /tmp/my-bridge-token &

# 2. It prints a URL and a short code. Approve as yourself:
#    (through the PROXY -- the hub alone will reject you as unauthenticated)
curl -s -X POST $PROXY/api/v1/device/approve \
  -H 'Content-Type: application/json' \
  -d '{"user_code":"<the code it printed>","approve":true}'

# 3. The bridge is polling; it stores the pair and exits on its own.
```

### Three things that will reject you outright if you script the HTTP directly

Learned the hard way while migrating the test suites; each one is a hard refusal, not a
warning:

1. **`bridge_public_key` must be a 130-char lowercase-hex uncompressed P-256 point**
   (`04` + 128 hex chars). A short placeholder is refused at the HTTP layer. Note the
   SERVICE layer only checks non-empty, so a direct-service fixture can use a stub and an
   HTTP one cannot — that asymmetry is real and will confuse you once.
2. **Do NOT send `bridge_key_fingerprint`.** The Hub derives it from the key and refuses a
   body-supplied one that disagrees. A requester-chosen fingerprint would defeat the entire
   point of the human comparing it on the approval screen.
3. **PKCE is MANDATORY for a bridge grant, and S256 only.** `plain` is refused, and so is
   a missing `code_challenge_method`. Precompute `BASE64URL(SHA256(verifier))` unpadded
   (43 chars) and replay the verifier at `/device/token`. A reusable pair:
   verifier `heimdall-req-impl-6-test-code-verifier-aaaa`,
   challenge `J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI`.

### And two behaviours that are correct but look wrong

- **A spent grant replays as HTTP 200** carrying `{"status":"expired"}`, not a 4xx. The
  device-flow protocol reports grant state in the body. Assert on the absence of
  `access_token`, not on the status code.
- **Capabilities are REPORTED, not enrolled.** The deleted endpoint accepted a
  `capabilities` array at enrollment; the device flow has no such field, because the Hub
  records only what the approving human confirmed. A bridge declares its providers when it
  CONNECTS. So a freshly enrolled, never-connected bridge has **no providers**, and
  anything matching an agent to a provider/tier fails until it connects. That is intended.

### A bridge that was enrolled the old way

Every bridge holding a pre-device-flow `hbr_` credential **stops working** at this change
and must re-enroll. It is told so explicitly rather than getting a bare 401 — the Hub
replies:

> `this bridge's credential was issued by the removed enrollment flow and is no longer
> accepted; re-enroll this machine with: ham-bridge enroll --hub <your-heimdall-url>`

`ham-bridge status` prints the same instruction.

---

## 10a. Device-grant enrollment with EXPIRING credentials, and proving revocation (verified 2026-10-07, REQ-IMPL-3)

§10 above is the **current and only** enrollment flow: browser approval, driven by
`ham-bridge enroll --hub` (and by `scripts/dev-stack.sh enroll`, which wraps it). The
legacy pre-shared `hbe_` flow this section used to contrast itself against is **deleted**
as of REQ-IMPL-6 — its endpoints return 404, so there is nothing left to compare against.

This section sits one level BELOW §10. Use §10 to enrol; use this section when you need to
drive the individual HTTP legs yourself — to inspect the **expiring credential pair** the
flow issues, or to prove rotation, reuse detection and revocation, none of which
`ham-bridge enroll` exposes.

**What you get.** `POST /api/v1/device/token` returns a PAIR, not a token:

```json
{"status":"approved","access_token":"hba_btk_...","bridge_id":"brg_...",
 "refresh_token":"hbf_btk_...","refresh_expires_in":2592000,"expires_in":3600}
```

- `hba_` — 1 hour, used for the WS connect and every Hub API call.
- `hbf_` — 30 days sliding, accepted at **`POST /api/v1/device/bridge-refresh`** and nowhere
  else. Single-use: every refresh returns a new pair and kills the presented token.
- `expires_in`/`refresh_expires_in` are **durations**, never timestamps, so a bridge with a
  wrong clock still renews correctly — schedule off a monotonic timer.

**Four behaviours that will look like bugs if you do not expect them:**

1. **`bridges.bridge_token_hash` is EMPTY for a device-enrolled bridge.** Its credentials
   live in the `bridge_tokens` table. An empty stored hash verifies nothing, so this is the
   intended state, not a half-written row.
2. **A replayed refresh token kills the whole family.** Presenting an already-rotated
   `hbf_` is treated as theft: every generation and both kinds are revoked, and the bridge
   must re-enrol. There is a **30-second grace** for the immediately-previous token only
   (crash recovery), so to test the theft path you must wait >30s after rotating.
3. **`POST /api/v1/bridges/<id>/revoke` now kills the live WebSocket**, not just the DB row
   (audit F6). Expect an immediate EOF on a held socket — measured at 0.000s locally.
4. **Four different refresh failures all return one `401 invalid_grant`** — expired,
   unknown, already-used and revoked. That is deliberate (no enumeration oracle); the hub
   log distinguishes them.

**Reproducing it end to end.** The script used for REQ-IMPL-3's acceptance evidence walks
authorize → verify → approve → poll → API call → live WS → revoke → "socket died, refresh
refused", plus rotation, reuse detection and two-bridge isolation. It needs no dependencies
beyond python3 (it hand-rolls the WebSocket handshake, ~40 lines) and runs against an
isolated stack per §1a:

```bash
# Build from the WORKING TREE (§1b: nix cannot see untracked files)
nix develop --command bash -c '
  odin build src/hub       -collection:odin_test=src -out:/tmp/ham-req3-stack/ham-hub
  odin build src/dev_proxy -collection:odin_test=src -out:/tmp/ham-req3-stack/ham-dev-proxy'
. scripts/lib/hub-oidc-dev.sh; hub_oidc_start_mock /tmp/ham-req3-stack tanmay; hub_oidc_export_env
/tmp/ham-req3-stack/ham-hub --listen 127.0.0.1:8291 --db /tmp/ham-req3-stack/hub.db \
  --migrations-dir src/hub/repository/sqlite/migrations --ui-origin http://127.0.0.1:8290 &
/tmp/ham-req3-stack/ham-dev-proxy --listen 127.0.0.1:8290 --hub-url http://127.0.0.1:8291 \
  --default-user tanmay &
python3 /tmp/ham-req3-stack/e2e.py     # see the REQ-IMPL-3 task comments for the script
```

**Two traps found while writing that script:**

- **`ham-ctl shell serve --cmd 'cd X && ...'` fails with `exec: cd: not found`.** The verb
  execs the command rather than running it through a shell, so a leading `cd` is not a
  builtin it can reach. Use `--cwd` instead; the error does not mention `cd` being a
  builtin and reads like a missing binary.
- **The `/device/authorize` and `/device/token` legs must go to the HUB (`:8291`), not the
  proxy** (they are the unauthenticated device-side ones). `verify`/`approve`/`revoke` need
  the human's browser session: sign in (`hub_oidc_login`) and send the session cookie plus
  `Origin` equal to the hub's `--ui-origin`. Mixing them up produces confusing 401s on the leg that is
  supposed to be public.

---

## 10c. Verifying a WIRE-FORMAT change — parse the JSON, do not eyeball it (verified 2026-10-07, REQ-IMPL-5)

If you add a field to a hand-built JSON response, **the smoke test must `json.tool`/`json.load` the
payload, not `grep` it.** These handlers assemble JSON with `strings.write_string`, so a field is
added by splicing quote characters into a string someone else closed — and the failure mode is an
unparsable body that still contains your field name, so a grep for the field PASSES on broken JSON.

That is not hypothetical: adding `server_time` to `hub_observed` in `device_auth_handlers.odin`
produced exactly this. `fmt.tprintf("\",\"server_time\":%d", ...)` closes the preceding
`request_ip` string itself, so the following chunk had to drop its own leading `\"` — otherwise the
object carried a stray quote before `}`. **`odin check` and `odin test` both passed with the broken
payload**, because nothing in the Odin suites parses the handler's output as JSON; only piping a
live response through a parser catches it.

```bash
# The shape of a wire-format check that actually fails when the JSON is wrong.
curl -s -X POST $PROXY/api/v1/device/verify -H 'Content-Type: application/json' \
  -d "{\"user_code\":\"$CODE\"}" | python3 -c '
import json,sys
d = json.load(sys.stdin)["data"]           # <- a malformed payload dies HERE
ho = d["hub_observed"]
print("hub_observed keys:", sorted(ho.keys()))
assert isinstance(ho["server_time"], int)
assert "server_time" not in d.get("host_asserted", {})   # provenance, not just presence
'
```

**Assert the PROVENANCE GROUP, not just the field.** `hub_observed` versus `host_asserted` is a
security contract in this tree (REQ-ENROLL-14), so a test that only checks `server_time` is present
would pass with the field in the wrong group — which is the defect worth catching.

### Running a working-tree hub when the prebuilt one is stale
`scripts/dev-stack.sh start` runs `./result-hub/bin/ham-hub`, a **nix symlink from the last
`build`** — it does not rebuild, so a `start` after editing hub sources silently tests the OLD
binary. With untracked files in the tree, `build` cannot see them either (§1b). What worked:

```bash
nix develop . --command bash -c 'odin build src/hub -collection:odin_test=src -out:/tmp/ham-iso5/ham-hub'
. scripts/lib/hub-oidc-dev.sh; hub_oidc_start_mock /tmp/ham-iso5 tanmay; hub_oidc_export_env   # OIDC is required
/tmp/ham-iso5/ham-hub --listen 127.0.0.1:8191 --db /tmp/ham-iso5/hub.db --ui-origin http://127.0.0.1:8190 &   # blocks; background it
nohup ./result-devproxy/bin/ham-dev-proxy --listen 127.0.0.1:8190 --hub-url http://127.0.0.1:8191 &
```
The dev-proxy needs no rebuild if you only touched hub code. **`ham-ctl shell serve` exited
immediately with an empty log** for the hub here and the port never bound; the same command under
`shell run` (backgrounded inside the command) worked. If `serve` reports `running` but
`ss -ltnp | grep <port>` shows nothing, the process is gone — check the port, not the status field.

---

## 10b. Device-grant APPROVAL smoke recipe — provenance split + `bridge_id` (verified 2026-10-07, REQ-IMPL-5)

§10a covers the bridge's side of the device grant. This is the **approving browser's** side: the
two responses the approval screen is built on. Useful whenever you touch
`device_auth_handlers.odin` or the approval UI, because both shapes are contracts the UI parses.

Run the stack per **§1a** (isolated ports, throwaway DB) and **§1b option A** (build from the
working tree — the enrollment files are untracked, so `nix build` cannot see them).

```bash
PROXY=http://127.0.0.1:8190
BPK=04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc
# A bridge grant REQUIRES PKCE S256 -- without a code_challenge authorize is refused.
VERIFIER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
# -> ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA  (43 chars; the same pair is hardcoded in
#    tests/device_auth_verify_approve_test.odin, so you can cross-check against it)

# 1. authorize. Echoes the HUB-COMPUTED fingerprint ("fb41 9516 cc0c f6ae" for the key above).
curl -s -X POST $PROXY/api/v1/device/authorize -H 'Content-Type: application/json' -d "{
  \"client\":\"ham-bridge\",\"device_label\":\"dawnstar\",\"os\":\"NixOS 25.05\",
  \"app_version\":\"0.9.1\",\"bridge_public_key\":\"$BPK\",\"os_user\":\"tanmay\",
  \"code_challenge\":\"$CHALLENGE\",\"code_challenge_method\":\"S256\"}"

# 2. verify -- the REQ-ENROLL-14 provenance split the approval screen renders.
curl -s -X POST $PROXY/api/v1/device/verify -H 'Content-Type: application/json' \
  -d '{"user_code":"<USER_CODE>"}' | python3 -m json.tool

# 3. approve -- returns the MINTED bridge id for the approver's browser.
curl -s -X POST $PROXY/api/v1/device/approve -H 'Content-Type: application/json' \
  -d '{"user_code":"<USER_CODE>","approve":true}'
# -> {"hub_observed":{"bridge_id":"brg_..."}}

# 4. the bridge's own poll still gets the credential pair, unchanged.
curl -s -X POST $PROXY/api/v1/device/token -H 'Content-Type: application/json' \
  -d '{"device_code":"<DEVICE_CODE>","code_verifier":"'$VERIFIER'"}'
```

### The two shapes, and why each half matters

**`verify`** nests every field under `hub_observed` (`bridge_key_fingerprint`,
`bridge_public_key_on_record`, `fingerprint_algorithm`, `request_ip`) or `host_asserted`
(`bridge_public_key`, `os_user`, `device_label`, `os`, `app_version`), **and keeps flat
top-level copies of the legacy fields** so the Electron page keeps working. `bridge_public_key`
appears in BOTH halves deliberately: the machine asserted it, and the Hub vouches for having
stored that exact value — which is what makes the fragment cross-check meaningful.

**`approve`** returns `{"hub_observed":{"bridge_id":"..."}}` for an approved BRIDGE grant and
**`{}` for everything else** — a rejection, and any non-bridge (Electron) grant. The browser needs
it because the vault key has to be delivered to one specific bridge, and until approval there is no
bridge to address. Verified against the live stack: the `bridge_id` here is the same value step 4
hands the bridge.

**Shape regressions worth re-checking after any edit here**, all verified 2026-10-07:
an Electron `authorize` response still carries no `bridge_key_fingerprint`; an Electron `approve`
still returns `{}`; a rejected bridge grant returns `{}`; and `GET /api/v1/device` still serves the
standalone Electron confirm page (200).

---

## 10d. End-to-end verification of the device flow — the 13-scenario harness (verified 2026-10-08, REQ-IMPL-7)

§10a drives the individual HTTP legs. This section is the layer above it: how to prove the
**operator-visible** properties — headless enrollment, proactive refresh, family
revocation, per-machine revocation, cross-bridge isolation and the legacy-credential
message — without a browser and without waiting an hour. Three reusable scripts live in the
REQ-IMPL-7 task comments; the recipes below are the parts worth keeping.

### Enrol a bridge with NO browser at all (`--headless`)

`--headless` is a real flag (`src/bridge/enroll_device_flow.odin:1116`), not just help text.
It **skips `bridge_enroll_callback_bind` entirely**, so no loopback listener is created and
the printed URL carries no `cb=` parameter. Approval then goes through the API and the
bridge picks it up by polling:

```bash
./result-bridge/bin/ham-bridge enroll --hub http://127.0.0.1:8295 --headless \
  --bridge-token-file /tmp/ham-r7/s4-token > /tmp/ham-r7/s4-enroll.log 2>&1 &
UC=$(grep -o 'user_code=[A-Z0-9-]*' /tmp/ham-r7/s4-enroll.log | head -1 | cut -d= -f2)
curl -s -X POST http://127.0.0.1:8295/api/v1/device/approve \
  -H 'Content-Type: application/json' -d "{\"user_code\":\"$UC\",\"approve\":true}"
# credential appears within ~6s, by polling alone
```

This is the fastest way to get N enrolled bridges for a multi-bridge test. **Approval goes
to the PROXY** (it needs the human identity the dev-proxy injects); see §10a's trap about
which legs go where.

### Proactive refresh is observable in ~20 SECONDS, not an hour

`BRIDGE_ACCESS_TOKEN_TTL_SECONDS` is a **compile-time constant** (3600), so you cannot
shorten it from the CLI or config. You do not need to. On a **fresh start** the bridge does
not know how much life its stored access token has left, so the first refresh is scheduled
at `BRIDGE_REFRESH_MIN_DELAY_SECONDS` = **30s**, and only then does it settle onto the 80%
schedule (`enroll_device_flow.odin:1003-1006`):

```
# start a bridge on a fresh credential, then:
ACCESS TOKEN ROTATED after 19s
bridge credential refreshed; next refresh in 3045s      # 80% of 3600, ±5% jitter → 2700-3060
```

So: **start the bridge, wait ~40s, and diff both token files.** Both halves must change.
Checking `next refresh in N` against the 2700–3060 window is what actually tests the 80%
arithmetic and the jitter — the rotation alone does not.

**What this does NOT prove,** and do not claim it does: a real 3600s access token reaching
its expiry. The hour boundary is not crossed. Proving that needs a build with a shortened
TTL constant.

### A socket count does NOT prove a live connection — `CLOSE-WAIT` will fool you

§10a says revocation kills the live WebSocket "immediately (0.000s)". That is true **of the
Hub's end**. Watched from the bridge side it looks like the socket survived:

```
t= 1s  A_sockets=1 ... t=20s  A_sockets=1      # never reaches 0
```

Because the surviving entry is a half-closed corpse:

```
CLOSE-WAIT 0 0 127.0.0.1:60656 127.0.0.1:8296 users:(("ham-bridge-wra",pid=967765,fd=7))
```

`CLOSE-WAIT` means **the peer sent FIN and this process has not closed its fd.** The Hub
did tear it down. Reporting `sockets=1` as "revocation did not close the socket" would be a
false FAIL on a passing control. **Always read the socket STATE, never just `grep -c`** —
and corroborate with the bridge's own log, which is unambiguous:

```
bridge hub runtime: connection closed, reconnecting…
bridge hub runtime: hub sent bridge_error after hello — token rejected or bridge not recognized
bridge credential REVOKED by the hub (invalid_grant): both tokens were wiped. RE-ENROLLMENT REQUIRED
```

Note the reconnect attempts that follow are logged as
`cannot connect WS … — proxy/tunnel down, hub unreachable, or TLS failed`, which **blames
the network for what is an auth refusal**. The actionable `REVOKED … RE-ENROLLMENT REQUIRED`
line is printed once, before that noise. Do not diagnose a revoked bridge from the tail of
its log.

### Cross-bridge isolation, and where the denial is recorded

A bare bridge token is confined to its own bridge (`agent_handlers.odin:155-194`,
REQ-ENROLL-15). Both halves need testing, and **the own-bridge control is what makes the
403s meaningful** — a token that 403s on everything would look identical:

```bash
BT=$(cat /tmp/ham-r7/s9b-token)      # bridge B's access token
curl -s -o /dev/null -w '%{http_code}\n' "$HUB/api/v1/agent-instances?bridge_id=$B" -H "Authorization: Bearer $BT"  # 200 control
curl -s "$HUB/api/v1/agent-instances?bridge_id=$A" -H "Authorization: Bearer $BT"   # 403 list
curl -s -X POST "$HUB/api/v1/agent-instances" -H "Authorization: Bearer $BT" \
  -d "{\"bridge_id\":\"$A\",\"agent_id\":\"...\",\"provider\":\"claude\",\"tier\":\"normal\"}"  # 403 create
```

The Hub records each denial on **its own stdout** (`<run-dir>/hub.log`), which is where to
look for the audit trail — it is not in the HTTP response:

```
ham-hub bridge_auth_denied point=cross_bridge_list   ... bridge_id=<B> target=<A>
ham-hub bridge_auth_denied point=cross_bridge_create ... bridge_id=<B> target=<A>
```

### The legacy-credential message, proven over the wire

The `hbr_` rejection must name the remedy rather than return a bare 401. To see it you must
present a credential naming a **real, currently-enrolled** bridge id — a made-up id fails
earlier, for the wrong reason:

```bash
SEC=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
curl -s "$HUB/api/v1/agent-instances" -H "Authorization: Bearer hbr_${REAL_BRIDGE_ID}.${SEC}"
# 401 "…issued by the removed enrollment flow…; re-enroll this machine with: ham-bridge enroll --hub <your-heimdall-url>"
curl -s "$HUB/api/v1/agent-instances" -H "Authorization: Bearer hbz_nonsense.secret"
# 401 "unsupported bearer token"   ← the control: a DIFFERENT, non-naming message
```

Without that second call the first proves only that *some* 401 was returned. The deleted
routes (`POST`/`GET /api/v1/bridge-enrollments`, `POST /api/v1/bridges/enroll`) all answer
`404 route not found`; pair that with a `POST /api/v1/device/authorize` that returns **400**
to show the 404s are about the route and not about your harness.

### Vault-key delivery: THREE different ECDH keys are in play, and two of them are dead ends

Before you debug a failed vault delivery, establish **which key the seal was addressed to**.
The bridge's ECDH pair is a per-process in-memory global (`src/bridge/unseal_protocol.odin:25-53`)
that is never persisted, and `ham-bridge enroll` **exits** after enrolling
(`src/bridge/main.odin:90-91`). So in a normal cold enrollment there are three:

| Key | Held by | Fate |
|---|---|---|
| the `bpk` in the approval link | the `ham-bridge enroll` process | dies when `enroll` exits |
| the Hub's stored `bridge_public_key` | the Hub | **overwritten by the live bridge at connect** |
| the live bridge's own pair | the long-running `ham-bridge` | the only one that can decrypt anything |

Measure it rather than assuming — they are plainly different:

```bash
grep -o 'bpk=[0-9a-f]*' <enroll-log>          # 045fff3de07097ab9…
curl -s $PROXY/api/v1/bridges/$BID | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["bridge_public_key"])'
                                               # 0439dfb806a6eb43f…  ← different
```

**Two failure strings and what each one means:**

- `AEAD tag verification failed: tamper detected or authentication failure` — comes from the
  **bridge** (`unseal_protocol.odin:275`). The envelope arrived and the recipient could not
  open it: the seal is addressed to a key that process does not hold. This is **not** a wrong
  master password.
- `The operation failed for an operation-specific reason` — the **browser** failed before
  sealing, which is what a wrong master password looks like (AES-GCM over the stored vault blob).

Those two live at different sites, which is what lets you tell "wrong password" from "wrong
recipient key". Assert on which one you got.

Also note `Waiting for the bridge to connect… Giving up in 37s` — delivery relays to a
**CONNECTED** bridge, so with no bridge running there is no target at all. The `enroll` process
is never a valid target: it holds only an HTTP poll loop, never a Hub WebSocket.

**Setting up a vault with a KNOWN password** (needed for any delivery test — the blob is
client-side PBKDF2-SHA256/100000 + AES-GCM and cannot be minted by hand): clear the row in a
throwaway DB and let the real UI create it.

```bash
nix develop --command sqlite3 $HUB_DB "delete from user_vaults;"   # throwaway DB ONLY
# then drive VaultOnboardingModal; it exposes data-debug-id selectors:
#   [data-debug-id=vault-onboarding-master-password-input]
#   [data-debug-id=vault-onboarding-confirm-password-input]
#   [data-debug-id=vault-onboarding-setup-backup-checkbox]   (submit stays disabled until checked)
#   [data-debug-id=vault-onboarding-setup-submit-btn]
```

---

## 10e. Atomic enrollment — a bridge is enrolled only once its vault key is delivered (REQ-EA, 2026-10-16)

Approving a bridge grant no longer enrolls the bridge. The Hub mints it **pending**, and three facts follow:

- **Approval writes nothing on the machine.** `ham-bridge enroll` sees `"enrollment_pending":true` in the token poll. It keeps its credential in memory and opens an **enroll-only** WebSocket. The registry key for that socket is `enroll:<bridge_id>`, and its token family has scope `bridge:enroll`, which authenticates only that socket.
- **A pending bridge is invisible by default.** `GET /api/v1/bridges` omits it unless `?include_pending=1` is passed, which Settings → Bridges does. `GET /api/v1/bridges/<id>/enrollment` reports `enrollment_state`, `enroll_connected`, `enroll_public_key` and `enrollment_pending_until`.
- **Commit happens on an observed ok:true.** `POST /api/v1/bridges/<id>/unseal` relays to the enroll-only socket.
  - The bridge answers ok:true only after it has stored the key, read it back from the OS keystore, and **staged** the token, refresh token and config.toml as `<file>.pending` siblings plus a `<token file>.enrolling` marker. The marker is written last; the live files are untouched.
  - The Hub then commits in **one SQLite transaction**: it promotes the token family to `bridge:runtime`, and either clears the pending column (new bridge) or revokes the old device's families (attach). A duplicate ok:true for an already-committed family is an idempotent success.
  - The Hub sends the bridge `bridge_enrollment_result`. On `committed:true` the bridge renames the staging into place. On `committed:false` it deletes the staging and purges the key; the previous files were never changed.
  - **Crash recovery.** Every service start and every `enroll` resolves leftover staging before reading the credential:
    - staging without a marker never reached the ack, so it is deleted;
    - with a marker, the staged refresh token is presented to the Hub, which refreshes only a committed family. A rotation promotes the staging with the rotated pair; `invalid_grant` deletes it and purges the key; an unreachable Hub keeps it for the next start.

**Rollback.** Pending enrollments roll back in two ways:
- `POST /api/v1/bridges/<id>/enrollment/cancel`;
- the reaper, at the 300 s deadline, and also once at Hub startup.

Either way the Hub revokes the family and **hard-deletes** a new bridge's row. An attach leaves its target untouched. The enrolling process prints `enrollment rolled back` and exits 1. On the `heimdall-ct` page, any exit other than 0 or 3 therefore no longer triggers a service restart.

**Verify it.** Run `tests/e2e_req_fix_2_vault_delivery.sh`. It drives the real binaries through three scenarios: success (preceded by a refused delivery), cancel, and an enroll process killed mid-wait. A failed delivery must leave the enrollment `pending`, so the operator can retry before the deadline.

**Compatibility.** The e2e script also builds the `v0.4.1` bridge (`LEGACY_REF`) and enrolls it against this Hub. That bridge ignores `enrollment_pending` and writes its credential at approval, but its ok:true still commits, and its restarted service comes up enrolled and unlocked. Its rollback cannot clean up its own files (it predates staging); the Hub still revokes the credential.

**fmt trap.** In Odin's `fmt`, `{` and `}` are placeholders: a JSON template needs `{{`/`}}`. An unescaped one silently yields `%!(MISSING CLOSE BRACE)…`.

## 11. Checking logs

```bash
tail -f .run-logs/hub.log
tail -f .run-logs/bridge.log
tail -f .run-logs/dev-proxy.log

# Filter for bootstrap-related lines in bridge log
grep -i "bootstrap\|manifest\|template\|placed\|rendered\|persona" .run-logs/bridge.log | tail -30

# Filter for errors
grep -iE "error|FAIL|panic" .run-logs/hub.log | tail -20
```

---

## 12. Running tests

```bash
# See §1 for the pin, and note the binary reports `dev-2026-09` while the derivation is
# named `odin-dev-2026-07a` -- one toolchain. `nix develop -c odin ...` is preferable.
ODIN=/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/bin/odin
export LIBRARY_PATH=/nix/store/7a0nx1a0rdc5s07vxrsdhplqnzncl5z9-sqlite-3.53.3/lib:$LIBRARY_PATH

# Hub unit tests + golden test (fragment rendering, BT-2/BT-2a variables)
$ODIN build tests/hub_bootstrap_golden_test -collection:odin_test=src -out:/tmp/gt && /tmp/gt

# Bridge @(test) suite (includes BT-3 substitution/role-conditional engine)
$ODIN test src/bridge -collection:odin_test=src -out:/tmp/bridge_test
# ⚠️ The pre-existing permission_relay_integration_test is flaky under the parallel
# runner (passes in isolation). It is unrelated to bootstrap/template code.
# Run a specific test: -define:ODIN_TEST_NAMES=main.bt3_e2e_real_template_coordinator

# Wrapper @(test) suite (includes BT-4 placement + prune)
$ODIN test src/wrapper -collection:odin_test=src -out:/tmp/wrapper_test

# Web Push (@(test) suite: crypto RFC 8291 Appendix A vector, VAPID JWT,
# subscription service + payload/send logic)
$ODIN test src/hub/service/push -collection:odin_test=src -out:/tmp/push_test

# Via flake (if nix on PATH):
nix build .#ham-bootstrap-golden-test && ./result/bin/ham-bootstrap-golden-test
nix build .#ham-push-crypto-test && ./result/bin/ham-push-crypto-test
nix build .#ham-push-repo-test && ./result/bin/ham-push-repo-test

# Regenerate goldens intentionally (do only for deliberate output changes):
HEIMDALL_GOLDEN_UPDATE=1 /tmp/gt
```

---

## 13. Known gotchas & discoveries

| When | Discovery |
|---|---|
| 2026-10-07 | **`nix build` CANNOT build this chain's work at all while the git freeze is in force, so `dev-stack.sh build` and `start` are unusable for verifying it.** Flakes copy git-tracked files only (§1b), and this chain added several files that are still untracked — `bridge_token_service.odin`, `migrations/057_bridge_tokens.sql`, `bridge_refresh_handler`. The freeze forbids `git add`, including `git add -N`, so **workaround B in §1b is unavailable** and workaround A is the only route. The failure is loud but misleading: `Undeclared name: issue_bridge_token_pair`, `Failed to #load … 057_bridge_tokens.sql`, `'bridge_refresh_handler' is not declared by 'http'` — three errors that all look like broken code and are purely nix's missing files. **Build with `odin build src/hub|src/dev_proxy|src/bridge -collection:odin_test=src -out:/tmp/…` and run those binaries manually (§1).** Verified REQ-IMPL-6 end-to-end that way. |
| 2026-10-07 | **`grep` silently finds NOTHING in a file containing a NUL byte, and sweeps that use "empty output" as the success signal therefore PASS VACUOUSLY. Use `grep -a` for every such sweep.** Reproduced on `tests/ui_device_approval_safety_test.ts` (one NUL at line 80): `grep -c import` prints nothing at all, `grep -ac import` prints `3`. **The trap has a second floor:** probing for the problem with `grep -rlI ''` / `grep -rl ''` does not reveal it either — both skip the file, so a "which files are binary?" check comes back clean and you conclude your sweep was fine. Only `-a` is trustworthy. |
| 2026-10-07 | **`fmt.tprintf` is NOT safe for a request body (or path/query) handed to `router_dispatch` in a test — the handler can read overwritten bytes.** `tprintf` returns per-thread TEMP-allocator memory and dispatch calls `tprintf` freely downstream, so the ring can be reused in place before the handler parses the body. Cost: a `bridge_id` in a cross-bridge test read back as EMPTY, which silently turned the authorization check OFF and produced `404 agent not found` instead of the expected `403`. It looked like a broken authorization check and was a corrupted request. **Build request bodies with `strings.concatenate` (heap) and `defer delete` them.** Same family as the `generate_id`/temp-allocator note elsewhere in this doc. |
| 2026-10-07 | **7 of the 13 standalone `tests/*.odin` binaries were ALREADY FAILING at pristine HEAD, so a red one is not evidence about your change — measure the baseline before attributing anything.** Red at HEAD with these exact messages: `hub_cards_api` ("task with an agent reviewer must NOT be projected as a card"), `hub_scheduled_prompts_api` ("expected 409 Conflict on double execution, got 200"), `hub_agent_instance_display_name` ("create Reviewer agent must succeed"), `hub_bootstrap_manifest_conditional` ("manifest assembly must include the identity fragment", `iss_18dc60d091a77782`), `hub_phase7_project_http` ("validation must fail when selected Bridge is not live" — **unsatisfiable by construction**: it wants status 503 AND body `bridge_offline`, but that code string only comes from `Error_Code.Bridge_Offline`, which `respond.odin` maps to **409**), `hub_phase5_bridge`, `hub_phase5_bridge_http`. Nothing runs these in a gate, so they drift. **How to baseline without touching git state:** `git archive HEAD \| tar -x -C /tmp/headtree` — `git archive` is read-only and writes only to `/tmp`, so it is safe under the freeze — then build and run the binary there with the same toolchain and diff the messages. |
| 2026-10-07 | **`git diff HEAD` in this repo shows the WHOLE CHAIN'S uncommitted work, not your own.** Everyone shares one dirty tree while the freeze holds, so "my" diff legitimately lists `package.json`, `device_auth_*`, `AppShell.tsx`, `clock.odin` and more. For attribution, `git diff --stat HEAD -- <path>` coming back **empty is sound NEGATIVE evidence** (nobody in the chain touched it, so behaviour there matches HEAD); a non-empty result proves nothing about **who**. Use it to clear a file, never to claim one. |
| 2026-10-07 | **`dev-stack.sh` needs an isolated `RUN_DIR`, not just isolated ports, or one agent's `stop` kills another's stack.** `stop` kills whatever the pidfiles under `RUN_DIR` name, and `RUN_DIR` was hardcoded to `$ROOT/.run-logs`. Now overridable: **`HAM_DEV_RUN_DIR`**, alongside `HAM_DEV_HUB_ADDR` / `HAM_DEV_PROXY_ADDR` / `HAM_DEV_BRIDGE_PORT` / `HAM_DEV_BRIDGE_LOCAL_ENDPOINT_PORT` / `HAM_DEV_HUB_DB` / `HAM_DEV_BRIDGE_RUN_DIR`. Isolating it exposed a second latent bug, also fixed: `_fix_bridge_config` required `$BRIDGE_CONFIG` to already exist and merely WARNED when it did not, so a fresh stack launched the bridge with `--config` pointing at a missing file; it now seeds from the repo's `config.toml`. |
| 2026-10-07 | **Omitting `-collection:odin_test=src` makes an `odin test` line fail while a `\| tail` pipeline still exits 0, so it reads as a pass.** Raised by this chain's reviewer against a handoff whose commands had it missing. Always include it, and never take the exit status of a pipeline ending in `tail`/`head` as the test's own result — `grep -c '\[ERROR\]'` plus the `Finished …` line is the signal. |
| 2026-10-07 | **`odin test src/hub/transport/http` can HANG indefinitely with no summary and `grep -c ERROR` = 0 — and a hang is indistinguishable from "still running".** Observed once: output stopped mid-suite after `test_bridge_connect_*_telemetry_*` / `shell first frame after attach`, then 20 minutes of nothing. **The identical tree re-ran clean (`Finished 248 tests … All tests were successful.`, RC=0), so it is a suite flake in the bridge-connect/shell-attach area, not a code defect — but note the evidence is "a re-run of the same tree passed", NOT an inverted-change proof, because it did not recur.** Triage: check whether the log's mtime is still advancing (`ls -la --time-style=+%H:%M:%S`) before concluding anything; a stalled mtime with no summary means hung, so kill and re-run once before investigating your own change. |
| 2026-10-07 | **`pkill -f <pattern>` matches the AGENT SHELL'S OWN eval string and kills your session (exit 144).** Recorded earlier in this chain and walked into again while killing a hung `odin test`. Kill by PID (`ps aux \| grep '[o]din test' \| awk '{print $2}'`) or use `ham-ctl shell kill <session_id>`. |
| 2026-10-07 | **A hand-built JSON field can pass `odin check`, `odin test` AND a grep, and still emit unparsable JSON.** Adding `server_time` to `hub_observed` left a stray `"` before `}`; nothing in the Odin suites parses handler output, so only piping a live response through `json.load` caught it. **Verify a wire-format change by PARSING a live response, and assert the provenance group (`hub_observed` vs `host_asserted`), not just the field's presence.** See §10c. |
| 2026-10-07 | **`dev-stack.sh start` runs the LAST-BUILT nix binary, not your edits.** It execs `./result-hub/bin/ham-hub` and never rebuilds, so a `start` straight after editing hub sources collects evidence from a binary that predates the change. Build to a temp path with `odin build` and run that (§10c). Also: `ham-ctl shell serve` reported `running` for the hub while the port was never bound and its log stayed empty — trust `ss -ltnp`, not the status field. |
| 2026-10-07 | **`scripts/dev-stack.sh build` cannot see a new `.odin` file until it is `git add`ed** — nix flakes copy git-tracked files only, so you get `Undeclared name:` for your own procs while `odin check` passes. Full explanation, both workarounds and the `/build/<hash>-source/` tell are in **§1b**; kept there rather than duplicated here. |
| 2026-10-07 | **Odin toolchain — SUPERSEDES the 2026-09-03 row below. Use `odin-dev-2026-07a`.** The `2026-05` store path this doc pinned has been garbage-collected, and on a 2026-05 compiler the tree fails in `src/hub/service/push/webpush_encoding.odin:52` (`base64.decode` 4-arg signature, this toolchain's core only). `odin check src/hub` is clean on it, so the old `.Haiku` warning no longer applies — if you hit it, you are on an older compiler. Prefer `nix develop -c odin ...` over any store path. |
| 2026-10-07 | **`2026-07a` is a DERIVATION NAME, not a compiler version — `odin version` reports `dev-2026-09` and that is correct.** `nix develop . --command odin version` prints `dev-2026-09` from inside `/nix/store/4p3p3...-odin-dev-2026-07a/bin/odin`. One toolchain, two labels. Every "2026-07a" claim in this doc and in this chain's evidence refers to this binary, so a version mismatch is **not** a finding and nobody's measurements are invalidated. Pin and compare on the **store path**. |
| 2026-10-07 | **Linking the hub:** without nix providing it, `odin build`/`odin test` on `src/hub` fails with `cannot find -lsqlite3`. That is a LINK error, not your code — `export LIBRARY_PATH=/nix/store/7a0nx1a0rdc5s07vxrsdhplqnzncl5z9-sqlite-3.53.3/lib:$LIBRARY_PATH`. |
| 2026-10-07 | **`odin test src/hub/transport/http` (244 tests, ~2min) is FLAKY under the 4-thread parallel runner — a DIFFERENT test fails each run, and all three observed failures pass in isolation.** Seen so far: `demo_disconnect_reason_read_deadline` ("could not dial loopback" / "could not accept on loopback"), `test_patch_bridge_telemetry_offline_does_not_dispatch` ("expected persisted.telemetry_enabled to be enabled"), and `test_rest_taskchain_and_task_subscription_handlers` ("delete must report removed:true"). Across 8 observed parallel runs by three separate agents: 244/244 ×3, plus single failures in the above. Tracked as `iss_18dc4e2a4cb35724`. **Before blaming a change, re-run the single test with `-define:ODIN_TEST_NAMES=http.<name>`** — all three passed that way. **`-define:ODIN_TEST_THREADS=1` is the reliable gate: verified `Finished 244 tests in 5m31.611226049s. All tests were successful.`** (and that run was made at host load average ~8.72 with another full suite running, so it survived heavy EXTERNAL contention — what it isolates is the suite's own intra-suite parallelism, not all contention). Note the runtimes separate two distinct causes: `demo_disconnect_reason_read_deadline` runs in 0.16s alone and fails with bind errors ("could not dial/accept on loopback") — a fixed-port race; the other two take 12s and 14s alone and fail on a wrong RESULT — shared test-DB/timing contention. A fix for one is not a fix for the other. Treat "N/244 with a different N each time" as the signature of this flake, not of a regression. **TRIAGE RULE, and read it before you believe any reported test name: the name the runner reports is the LAST assertion to fail, not the cause. Scroll back to the FIRST error in the output.** Verified 2026-10-07: a reported `test_patch_bridge_telemetry_dispatches_runtime_command` had its real first error 14 lines earlier at `bridge_telemetry_test.odin:107` — the fixture's `sqlite.run_migrations` returning `Internal_Error`. **So the cause count is TWO, not three or four:** (a) the loopback bind race, and (b) **per-test SQLite fixture setup failing under concurrent load**, which is the single cause behind the telemetry failures AND the `SQLITE EXEC ERROR: disk I/O error` in `setup_update_test_fixture` (disk exhaustion ruled out: 337G free, 10% inodes). Start at per-test DB isolation and migration serialisation, not at the individual named tests. |
| 2026-10-07 | **`odin test src/bridge` currently ABORTS before printing a summary, and it is NOT your change.** It ends `free(): invalid pointer`, exits **134** (SIGABRT), and prints **no** `Finished N tests` line, while reporting errors in `fs_management_test` (vault file read/grep/write), `shell_enc_spec_test` (pty plaintext frame) and `bootstrap_template_engine_test` (`AGENTS.md should exist`). Because there is no summary, **a passing run and a failing run look identical at the tail**, and because it aborts, tests after the abort never run. Confirmed pre-existing by running the suite with one change inverted and diffing the error sets — byte-identical, same abort at the same output line, same RC. **So do not read this as a regression, and do not read a tail-of-output as evidence either way.** To verify your own tests in this package, name them: `-define:ODIN_TEST_NAMES=main.<test>,main.<test2>` — that path prints a real `Finished N tests ... All tests were successful.` |
| 2026-10-07 | **`tests/*.odin` are standalone `odin run` PROGRAMS, not `@(test)` suites — and both wrong invocations exit 0.** `odin test tests` fails with `Syntax Error: Different package name` (each file is its own package), and `odin test tests/<file>.odin -file` prints **`No tests to run.`** and exits 0, which reads exactly like a pass of a suite that has no tests. The correct form is at the top of each file: `odin run tests/<file>.odin -file -collection:odin_test=src`. They assert with their own `fail`/`assert_eq` helpers and print **`ALL PASS`** on success, so **`ALL PASS` is the string to grep for** — not `Finished`/`successful`. The device-grant suites (`device_auth_verify_approve_test`, `device_auth_token_poll_test`, `device_auth_security_matrix_test`, `device_auth_grant_store_test`) all live here, so a change to `src/hub/service/device_auth` is NOT covered by any `odin test` invocation. |
| 2026-10-07 | **Two traps while bringing the isolated stack up by hand.** (a) **`ham-ctl shell serve` starts the process even if your parsing of its JSON reply fails** — if you re-run it thinking the first one did not start, you get two hubs on one DB and the second dies with `SQLITE EXEC ERROR: database is locked` / `migration failed: 001_foundation.sql`. That error means *you started two*, not that the DB is corrupt: kill the extras and the same DB migrates fine. Check with `pgrep -af <binary-path>` before re-issuing a `serve`. (b) **`pkill -f <pattern>` matches your own shell command line**, because the agent shell wraps commands in an `eval '<your command>'` that contains the pattern — so `pkill -f ham-hub` kills the shell running it and you get exit **144** with the cleanup half-done. Kill by PID (`for p in $(pgrep -f ...); do kill $p; done`) or use `ham-ctl shell kill <session>`. |
| 2026-10-07 | **An `odin test`/`odin check` line WITHOUT `-collection:odin_test=src` fails instantly — and piped through `tail` it still exits 0, so it reads as a pass.** Every package in this tree imports through the `odin_test:` collection, so omitting the flag is not a style choice, it is a hard failure (`Error: Unknown library collection`). The trap is the reporting, not the error: `odin test ... | tail -3` exits with **tail's** status, so a copy-pasted command missing the flag prints a few lines of error and returns success. Caught by the REQ-IMPL-3 reviewer in a handoff's own command list. **If you quote a test command anywhere — a comment, a handoff, this doc — include the flag**, and if you pipe it, check the real status with `${PIPESTATUS[0]}` or drop the pipe. |
| 2026-10-07 | **A COUNT OR A LINE NUMBER IN A COMMENT IS A FUTURE LIE — and "N per X" is a CLASS to sweep for, not a sentence to fix.** Four copies of one false per-call-site claim in `bridge_credential.odin` survived **three** separate fix passes, each pass believing it had got them all. Five numbers rotted during this chain alone: `verify_credential_miss` call sites (2→6), its `-o:speed` dummy refs (2→4), two hardcoded `:line` refs that both moved, `service/bridge` tests (16→26), `transport/http` tests (244→248). Write the **invariant** instead — *"every call site"*, *"one copy of its body, however many callers exist"*, *"an owned string for every text column"* — which stays true when the count changes. Sweep a file you touch with:<br><br>`grep -nE "at each caller\|per caller\|per call site\|once per surviving\|one ref per\|both call sites" <file>` — expect only NEGATIONS<br>`grep -nE "^//.*\.(odin\|nix\|sql):[0-9]" <file>` — expect NONE<br><br>**The grep is a floor, not a ceiling.** The fourth surviving copy used grammar none of those patterns matched and was found only by reading the prose, so a clean sweep is **not** proof. The chain description carries this as a chain-wide rule. (The two greps miss counted nouns too — `"thirteen owned strings"`, `"the three fields below"` — so also scan for number-words next to a plural.) |
| 2026-10-07 | **`fmt.tprintf` cannot carry a literal `{`:** this project's Odin `fmt` uses `{}` verbs, so `fmt.tprintf("{\"k\":\"%s\"}", v)` yields `%!(MISSING CLOSE BRACE)...`. Build JSON test bodies with `strings.concatenate` instead. The same applies to `assert_eq` labels using `{}`. |
| 2026-09-03 | ~~**Odin toolchain:** use `odin-dev-2026-05` from `/nix/store`; the `2026-07a` build errors on `.Haiku` OS enum in `wrapper_endpoint.odin`.~~ **Stale — see the 2026-10-07 row above.** |
| 2026-09-03 | **Project creation:** field is `default_path`, not `path`. |
| 2026-09-03 | **Chain coordinator:** `role` is NOT a field in `POST /api/v1/agent-instances`. Set coordinator post-launch via `POST /api/v1/task-chains/<id>/members` with `{"agent_instance_id":"...", "role":"coordinator"}`. |
| 2026-09-03 | **Chain member add:** requires `agent_instance_id` (not `agent_id`). |
| 2026-09-03 | **Standalone launch auto-creates a chain:** if you launch an agent without a `chain_id`, the hub creates a personal chain automatically and assigns the instance as coordinator. |
| 2026-09-03 | **`Coordinator:` line empty:** if no member is set as coordinator on a chain, `chain.coordinator_agent_instance_id` is empty → the bridge renders `Coordinator: ` (empty). Not a bug in the template engine. |
| 2026-09-03 | **Template identity:** `template_persona`/`template_instructions` only appear in the bootstrap if the agent has a `template_id` that resolves via `content_get_template`. Daemon deletion (BT-6) does NOT remove the template API path — templates are seeded via `POST /api/v1/templates` + `ham-ctl agent templates create`. |
| 2026-09-03 | **Bridge run dir layout:** `<bridge-run-dir>/instances/<inst_id>/` contains `CLAUDE.md`/`AGENTS.md`, `.pi/skills/*/SKILL.md`, `.heimdall/bin/ham-ctl`, `heimdall-bootstrap-manifest.json`, `.heimdall-wrapper-placed`. |
| 2026-09-03 | **`wrapper.bootstrap.list` RPC:** the bridge local endpoint is a unix socket (`<bridge-run-dir>/bridge.sock`), not an HTTP port. The wrapper calls it over the socket; you can't curl it directly from outside the bridge process. |

| 2026-10-08 | **`grep -ran 'A|B|C'` is BRE: the `\|` is a LITERAL character, so the pattern matches one 70-char string that exists nowhere and the sweep returns ZERO.** Walked into by a reviewer whose issue (`iss_18dc6a9916ae246c`) concluded "no test asserts this" from such a sweep; the test existed and had for two commits. Run verbatim it returns `lines=0`. **Use `-E` (or `rg`), and pair every sweep with a positive control that MUST match** — a sweep with no control cannot tell "absent" from "my matcher is broken". |
| 2026-10-08 | **A text sweep CANNOT establish that a behaviour is untested, even with a correct regex — because tests assert on FRAGMENTS, not on the artifact.** Generalises the row above and is the sharper rule. `iss_18dc6a9916ae246c` swept for the message text `re-enroll this machine`; the real test asserts `strings.contains(err.message, "ham-bridge enroll --hub")` and `"re-enroll"`, so **no amount of regex-fixing would ever have found it** (corrected to `-E` the sweep returns 8 lines, still not the test). To answer "is this tested?", **invert the behaviour and run the suite** — a green run then proves the gap. Never grep for it. |
| 2026-10-08 | **`CLOSE-WAIT` makes a torn-down socket look alive: `ss \| grep -c` never reaches 0 after revocation.** The Hub FINs immediately, but the bridge process holds its fd, leaving one `CLOSE-WAIT` entry indefinitely. Counting sockets therefore reports "revocation did not close the connection", which is false. **Read the socket STATE, not the count** (`ss -tnp` and look for `ESTAB` vs `CLOSE-WAIT`). See §10d. |
| 2026-10-08 | **You cannot shorten the bridge access-token TTL to test refresh — it is a compile-time constant (`BRIDGE_ACCESS_TOKEN_TTL_SECONDS :: 3600`).** You do not need to: on a **fresh start** the first refresh fires at `BRIDGE_REFRESH_MIN_DELAY_SECONDS` = 30s by design, because the bridge cannot know its stored token's remaining life. Wait ~40s and diff both token files; assert `next refresh in N` falls in 2700–3060 to test the 80%+jitter arithmetic. **This does not exercise a real expiry** — say so rather than claiming the hour boundary. See §10d. |
| 2026-10-08 | **A revoked bridge logs `cannot connect WS … proxy/tunnel down, hub unreachable, or TLS failed` on every retry — blaming the network for an auth refusal.** The one actionable line (`bridge credential REVOKED by the hub … RE-ENROLLMENT REQUIRED`) is printed **once, before** that noise, so diagnosing from `tail` of the log points you at the network instead of at re-enrollment. |
| 2026-10-08 | **`ham-ctl shell run` can fail for the whole bridge with `bridge failed to start shell session: unauthorized: invalid vault encryption`.** Observed 2026-10-08 on `brg_18c6785be1b4e5e6` while the local test stack (isolated ports) was perfectly healthy — so it is the **agent's own runtime bridge vault**, not your harness or the hub under test. Fall back to `nohup <script> > log 2>&1 &` for long runs and say that you did; do not read it as a failure of the thing you are testing. |

| 2026-10-08 | **A failed vault delivery has TWO different error strings at TWO different sites, and confusing them sends you to the wrong subsystem.** `AEAD tag verification failed: tamper detected…` is the **bridge** (`src/bridge/unseal_protocol.odin:275`) — the envelope arrived and the recipient lacks the matching private key; it is NOT a wrong password. `The operation failed for an operation-specific reason` is the **browser** failing before it seals, which IS what a wrong master password looks like. Three distinct ECDH keys exist in a cold enrollment (enroll-process / Hub's stored copy / live bridge) and only the last can decrypt — see §10d before debugging. |
| 2026-10-08 | **A stale `result-*` symlink ARGUES FOR THE WRONG CONCLUSION: deleted endpoints answer 401 instead of 404, and `dev-stack.sh enroll` fails with flags the current source deliberately removed. Run `dev-stack.sh build` before believing either.** Hit by the REQ-IMPL-6 reviewer, who nearly filed a false finding. The tell: `dev-stack.sh enroll` reports `ham-bridge enroll requires --hub and --enrollment-token` — the PRE-REQ-IMPL-6 binary's text. Current `src/` prints `ham-bridge enroll requires --ui <https://your-heimdall-url> (or HAM_BRIDGE_HUB_URL)` (`src/bridge/main.odin:82`), and the full sentence `requires --hub and --enrollment-token` exists nowhere in `src/` (verified: `grep -arn 'requires --hub and' src/` → exit 1). **Do not discriminate by grepping `enrollment-token` alone** — that substring legitimately appears on 3 lines of current source, including the NEW binary's own tombstone `--hub and --enrollment-token were REMOVED` (`main.odin:84`), so it hits whichever binary you are on. Match the whole sentence, or just check for `--ui`. **Why this is nastier than the grep hazards in the rows above:** a vacuous grep merely fails to obstruct a wrong conclusion, whereas the stale binary actively supplies evidence for one — the 401 reads as a surviving authenticated route while absent sibling routes correctly give 404, and the error text names flags you can go and confirm were deleted. After `build`, 404 across the board. |

---

## 14. Bootstrap file cleanup — provider switch behaviour (verified 2026-09-03)

The wrapper's stale-prune path (`wrapper_bootstrap_prune_stale`, `src/wrapper/bootstrap.odin:159`,
added BT-4) is responsible for cleaning up old bootstrap files when the file set changes
between launches of the same instance. The prune is unit-tested and proven correct
(`bt4_prune_removes_stale_keeps_current` — removes stale skill/AGENTS files, keeps
current ones, cleans empty parent skill dirs, guards against traversal).

**What is guaranteed (live-verified):**
- Each *new* instance gets exactly one bootstrap file: `CLAUDE.md` for `provider=claude`,
  `AGENTS.md` for any other provider (e.g. `pi`). Both files never coexist in the same run dir.
- If a skill is added or removed between restarts of the same instance (same provider), the
  `.heimdall-wrapper-placed` record is diffed and the stale skill file is pruned.

**Limitation — provider switch via restart:**
`POST /api/v1/agent-instances/:id/restart` relaunches using the **hub's persisted instance
provider** from the WS `launch_agent` payload (see `bridge_runtime_launch_agent`,
`hub_runtime_client.odin:486`). `PATCH`ing the provider before restart is not sufficient —
the hub re-reads the stored value. Therefore, restarting a claude instance as pi within the
same instance run dir cannot be triggered via the normal restart API; you would need to
stop the instance and create a new one.

The prune code is correct and exercises on every re-materialise; the provider-switch path
is simply not reachable via restart because the hub controls the provider in the WS payload.
