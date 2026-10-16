# Task System v2 — specification and implementation status

Status date: 2026‑10‑16 · Branch `feat/task-v2` (cut from `main` @ 70e66b16) · Owner: tanmayvijay
Supersedes `docs/fsm_task_chain_engine.md` (never implemented) and the level‑triggered `reconcile_chain` engine (deleted in the first commit of this branch).

> **Not backward compatible.** The task API, ctl verbs, routes and UI hooks of the v1 task system are removed, not shimmed. Hub, bridge, `ham-ctl` and UI roll together.

---

## 1. Goals (what we kept, what we fixed)

| Keep from v1 | Fix from v1 |
|---|---|
| Fresh agent context per task | 11 task statuses + instance pointer → **5 ticket states + a lease** |
| Task = audit trail | Tasks stuck until a human ran `reconcile` → **event‑armed timers, no manual reconcile of any kind** |
| One worker, many reviewers | Agents starting the next task before finishing → **one lease per agent, enforced by a DB unique** |
| Humans read it like a ticket board | Agents re‑reading every comment on restart → **capped context pack, history fetched by id** |
| | Self‑certified "done" → **verify‑gated submit + strict‑AND review gate** |

Two chain kinds share one engine: **`ticket`** (humans/coordinator write the cards; board view) and **`workflow`** (a versioned definition materialises stage instances lazily; pipeline view). An agent cannot tell which kind it is in.

---

## 2. Model

### 2.1 Ticket states (stored, five)

```
Backlog → Ready → In progress → In review → Done
                     ↑______________|  (changes requested)
  any → Cancelled
```
- `ready ⇔ published ∧ deps done ∧ blocked_on = null ∧ no work lease ∧ kind = task`
- `Blocked`, `starting`, `finishing`, `validated_*` etc. do **not** exist as states: they are lease conditions or badges derived by the fold.
- `tasks.state` is a cached projection of `task_events`; a property test asserts `fold(events) == state`.

### 2.2 Lease (machine layer)

`task_leases(lease_id, task_id, attempt_no, holder_instance_id UNIQUE, kind work|review, review_role, bridge_id, provider, model, granted_at, confirmed_at, expires_at, hard_deadline_at, last_beat_at, extended_at, delivery wake|inline)` + partial `UNIQUE(task_id) WHERE kind='work'`.

Invariants: one lease per instance · one work lease per task · one live work lease per chain directory (until per‑lease worktrees, M5) · `in_progress ⇔ live work lease` · coordinator never leased · `kind=gate` never granted.

### 2.3 Attempts, facets, reviews, events

- `task_attempts(task_id, attempt_no, started_at, ended_at, holder_instance_id, outcome, counts_toward_budget)`. `attempt_no` increments on every work grant **except** after a `handoff`. Attempts caused by `replaced | dep_added | reopen` do not consume the budget (5).
- `task_attempt_facets(task_id, attempt_no, kind, v, body_json, writer, written_at)` — typed, versioned `{kind, v, …}` envelopes stored **verbatim** (never re‑marshalled; unknown fields survive). Kinds: `vcs` (bridge), `verify` (hub), `runtime` (hub), `handoff` / `artifacts` / `output` (agent); `findings` live on reviews.
- `task_reviews(task_id, attempt_no, role, reviewer_kind agent|user, reviewer_agent_id, reviewer_instance_id, verdict, findings_json)`. A new attempt invalidates prior reviews.
- `task_events(event_id, task_id, chain_id, ts_ms, actor_kind, actor_id, kind, payload_json)` — append‑only; the UI timeline and the fold read only this.

### 2.4 Brief (immutable after publish; `reopen` writes a new version)

```yaml
goal: ≤2k chars                       # what, not how
scope: { owns: [paths], must_not_touch: [paths] }
acceptance: [≤20 × ≤200 chars]        # each objectively checkable
verify: "odin test src/hub/..."       # runnable; "none" only with an output contract
inputs: ["#42", "output:T-12", "path"]
review_roles: ["reviewer"]            # fleet roles that must approve (default [])
requires_user_approval: false
assignee: agent_id?                   # template, not instance
bridge: bridge_id?                    # pin
auto_submit: false                    # M3
budget: { lease_ttl: 15m, hard_deadline: 60m, max_attempts: 5, verify_timeout: 20m }
```

### 2.5 Placement (per fleet row)

`task_chain_fleets(chain, agent_id)`: `roles_json` (`worker`/`reviewer`), `bridge_id`, `provider`, `model`, `bridge_models_json`, `capacity`, `idle_ttl_seconds`. Resolution: task pin → fleet row → chain directory bridge → coordinator bridge; recorded on the lease and in `lease_granted`. Editing a row never touches live leases ("restart on new placement" = non‑counting `expire(replaced)`).

---

## 3. Engine rules

### 3.1 One transaction per verb
Process‑wide `sqlite.tx_mutex`; every verb, timer fire and materialisation is one unit of work; the matcher runs **inside** it; network effects (wakes, resource‑changed) run after COMMIT. Lock order `tx_mutex → state_mutex` is asserted by `src/lib/lockorder`.

### 3.2 No manual reconcile — trigger table
| Event | Action |
|---|---|
| publish chain/task, create/update on live chain, priority, dep add/remove | `match_chain` (dep added to a leased task → non‑counting expire first) |
| lease released (submit/block/handoff) or expired | `match_chain`, arm `idle_ttl` |
| review posted, fleet upserted/deleted, reopen | re‑evaluate gates, `match_chain` |
| instance `done|cancelled` | workflow: `materialize_ready_stages`; ticket: `start_workflow` hook; both: `match_chain` |
| `start-success(instance)` | confirm pending lease |
| `on_instance_terminal` (one chokepoint for every death path) | `expire(instance_lost)` → `match_chain` (skipped while the bridge is offline: TTL decides) |
| instance idle / busy | arm / cancel `idle_grace` |
| bridge Online (hello) | re‑send unconfirmed grants; `stop[]` lease‑less fleet workers/reviewers of Active chains **on that bridge**; `match_chain` |
| `shell_exited` of a verify run | hub writes `verify` facet (M2) |
| `chain_closed` | reclaim all leases |
| hub boot | arm timers from columns; `match_chain` once per Active chain; heal lease‑less in‑progress rows |

### 3.3 Timers (`Timer_Service{clock, heap, fire_due}`)
TTL 15 min (any `ham-ctl` call or bridge `busy` push is an implicit heartbeat, throttled to one write/30 s) · hard cap 60 min (not extendable) · `idle_grace` 5 min · `grant_unconfirmed` 180 s (re‑send once, then expire) · `idle_ttl` from the fleet row (stops stranded idle instances) · `ready_unclaimed` 10 min alert · `blocked_on human` 24 h re‑alert · clock‑jump extension only when a jump is detected. Columns are the truth; a fire whose deadline moved is a no‑op; the heap is rebuilt on boot.

### 3.4 Review gate (M2)
`needed = fleet rows with role ∈ review_roles − approvals on this attempt`. Done ⇔ `needed = ∅ ∧ no request_changes this attempt ∧ (user approved if required) ∧ (independent re‑verify green when required)`. Any `request_changes` → Ready (new attempt, findings carried into `TASK.md`), other review leases expired. `review_rounds ≥ 3` → Backlog · blocked on human (oscillation guard). `review_roles = [] ∧ ¬requires_user_approval` → Done on submit. Author is **stopped** on submit (fresh context on changes).

### 3.5 Verify‑gated submit (M2)
`ham-ctl verify` runs `brief.verify` as a hub‑minted Run shell session in the chain directory (waits in ≤5‑min slices with heartbeats); the **hub** writes the `verify` facet from `shell_exited`. `submit(outcome=submitted)` requires a facet on this attempt with `exit_code = 0 ∧ head_at_start = head_at_end = submit.head ∧ dirty = false` (`dirty` may be null without a VCS directory). Hard rejects: empty summary, gate unsatisfied; everything else truncated with `truncated:true`.

---

## 4. Agent interface (`ham-ctl`)

The agent never sees the chain kind or the workflow definition. Every launch writes `<run_dir>/TASK.md` (M3; today a skeleton pack is forwarded with the wake) and the first call is `lease next`.

| Verb | Purpose | Status |
|---|---|---|
| `ham-ctl lease next` | current lease + pack, or inline grant via the matcher (never wakes the caller; `none` for coordinators; `409 lease_lost` for 5 min after your lease expired) | ✅ M1 |
| `ham-ctl lease heartbeat [--note "…"]` | extend TTL (≤ hard cap); note lands in the timeline | ✅ M1 |
| `ham-ctl verify [--independent]` | run `brief.verify`; hub records the facet pinned to head | 🔧 M2 |
| `ham-ctl lease submit --summary "…" [--handoff-file f] [--output-file f]` | verify‑gated; releases + stops you; → In review / Done | 🔧 M2 |
| `ham-ctl lease block --waiting-on human\|task:T‑x --reason "…"` | → Backlog with `blocked_on`; `gave_up` ≡ block on human | 🔧 M2 |
| `ham-ctl lease handoff --summary "…"` | release; same attempt continues with a fresh agent | 🔧 M2 |
| `ham-ctl review post --task T‑x --verdict approve\|request_changes [--findings-file f]` | reviewer verb (review lease) | 🔧 M2 |
| `ham-ctl task fetch <#event \| output:T‑x \| facet:T‑x:n:kind \| dir:… \| path>` | pull history/inputs on demand | 🔧 M2 |
| `ham-ctl task comment --task T‑x "…"` | event only, no protocol meaning, no wake | 🔧 M2 |
| `ham-ctl task list / show / task_chain show / context` | read‑only | ✅ kept |

Coordinator (ticket chains): `task create --goal --acceptance* --verify --input* --review-role* --assignee --bridge [--auto-submit] [--brief-file] [--draft]`, `task update`, `task depend T‑a --on T‑b`, `task publish` / `task_chain publish` (atomic, per‑task missing‑field list), `task cancel`, `chain summary set` (M3), `chain propose --file` (M3). Workflow chains: `workflow templates | define --file | run <name> --input k=v | status | output <run> <stage> | retry <run> <stage> [--cascade] | cancel` (M3b). Human‑only (UI/HTTP): publish, cancel, reopen, answer blocker, approve / request changes.

Removed (404, no shim): `task status`, `task set_current`, `task vote`, `task nudge`, `task(_chain) subscribe/unsubscribe`, `task_chain reconcile`, `/bridge/actionable-tasks`.

### 4.1 Worker transcript (ticket or workflow — identical)
```bash
ham-ctl lease next            # → lease ls_7f2a · T-42 · attempt 2/5 · TASK.md written
# … edit, git commit …
ham-ctl verify                # ▶ run session rs_77a1 · head 7c1d02e … ✓ exit 0 in 4m12s · tree clean
ham-ctl lease submit --summary "evict cache on detach-to-zero; per-session 1 MiB cap"
#   → In review (reviewer-a) · your process is stopped; next task arrives via a new launch
```
Reviewer:
```bash
ham-ctl lease next            # → review lease on T-42 attempt 2 · diff: base 60b9..head 7c1d
ham-ctl verify --independent  # re-run in an ephemeral worktree (M3)
ham-ctl review post --task T-42 --verdict request_changes --findings-file f.json
```

### 4.2 `TASK.md` (M3; order fixed, ≤8k tokens, brief + findings never truncated)
header (lease · attempt n/5 · round k · expires · hard cap · placement · *why this attempt exists*) → brief → where you are (`vcs` of previous attempt) → chain summary (≤60 lines, mechanical) → previous attempt (handoff, next_steps, verify result, last heartbeat note) → open findings (path:line) → 10‑line protocol card.

---

## 5. Workflow chains (M3b)

```json
{ "kind":"workflow","v":1,"name":"fix_flaky_tests",
  "inputs":{"repo_dir":{"type":"directory_id","required":true},"runs":{"type":"int","default":5}},
  "stages":[
    {"key":"explore","parallel":3,"brief":{"goal":"Shard {{stage.index}}/3 …","verify":"none","review_roles":[]},"output":"findings.v1"},
    {"key":"plan","needs":["explore"],"brief":{"goal":"Merge into one fix task per root cause …"},"output":"task_list.v1"},
    {"key":"approve_plan","kind":"gate","needs":["plan"],"brief":{"goal":"Approve the fix plan?"}},
    {"key":"fix","needs":["approve_plan"],"for_each":"plan.outputs[0].tasks","brief":{"auto_submit":true,"verify":"{{item.verify}}"}},
    {"key":"soak","needs":["fix"],"brief":{"goal":"Full suite {{inputs.runs}}× green","verify":"for i in $(seq {{inputs.runs}}); do … || exit 1; done","require_independent_verify":true}}
  ]}
```
Rules: a run = chain `kind=workflow` with an immutable definition snapshot; stage instances are created lazily when every `needs` stage is **complete** (all instances done); `for_each` expands over the ordered `output` facets at that moment; dependencies are explicit edges; idempotent via `UNIQUE(chain, stage_key, stage_index)`; gates are `tasks.kind=gate` materialised straight into In review (approve → done, request changes → stage failed); `retry <stage>` is refused when downstream is materialised unless `--cascade` (cancels downstream, re‑materialises with **carry‑forward**: unchanged‑and‑done items come back Done with linked evidence, removed items are flagged `orphaned work`, tree never reset). Humans/coordinators cannot `task create/update/depend` in a workflow chain (403).

Triage rule for the coordinator (M3): task list known now ∧ no repeated structure ∧ no mid‑run approval → tickets; otherwise workflow (template if one matches). It proposes (`chain propose`), the human approves, then it executes and reacts only to attention lines (`blocked_on human`, `stage_failed`, `budget_exhausted`, `oscillation`, `ready_unclaimed`, `run_complete`, `review_requested_from_user`).

---

## 6. HTTP surface (hub)

Agent actions (instance token; any call is an implicit heartbeat): `POST /api/v1/agent-actions/lease/next|heartbeat|submit|block|handoff`, `review/post`, `task/fetch`, `task/comment`. Owner API: chains/tasks CRUD + `publish|cancel|reopen|answer`, `POST …/tasks/{id}/review` (user approve/request changes), `GET …/tasks/{id}/events?before_id=&limit=`, `GET …/tasks/{id}/attempts/{n}/facets/{kind}`, fleets with roles/placement, `GET /api/v1/task-chains/{c}/directories/{d}/vcs/commit-diff?base&head&cursor&limit` (M3, relays the existing bridge VCS diff), workflow routes (M3b). WS: `publish_resource_changed(task|task_chain|agent_instance)` after COMMIT.

---

## 7. UI (M4) — mock: `~/.gemini/jetski/scratch/task-v2-mock/` (`index.html`, `compare.html`)
Aux‑pane Tasks tab = status summaries first (state bar + counts, attention chips, Fleet section with per‑row bridge/provider/model/capacity), then collapsible per‑state sections of compact cards (badges `⏱ holder · ttl`, `⌂ bridge`, `attempt n/5`, `round k`, `approvals k/n + you`, `⛔ blocked on you`). Workflow chains: pipeline view (run header, stage bar, stages with instances, gate cards). Shared detail view: status sentence, human verbs only, **Your review** block, Brief, Placement (+ pin), Changes (diff by reference), Verify (+ re‑run), Latest handoff, Output, Reviews, Timeline.

---

## 8. Milestones — done / to do

| M | Scope | Status |
|---|---|---|
| **M0** | Delete reconcile (+ CI grep test `tests/no_reconcile_symbol_test.sh`), migration `087_task_v2.sql` (+ idempotent twin), `tx_mutex`, v2 domain/repos, event log + fold, hub/bridge/ctl cutover, tests ported | ✅ `1c330b05 … 0583579f` |
| **M1** | `Timer_Service`, leases, matcher (placement, JIT within capacity, review leases excluding author template), wake with `lease_id` + pack skeleton, `lease next|heartbeat`, `on_instance_terminal`, bridge‑hello, boot healing | ✅ `8f3dd882 … 0d7aa121` |
| **M1 review fixes** | B1 lock order (`src/lib/lockorder`), B2 bridge blip ≠ death, B3 expire never matches; S1–S10 (grant‑time budget, timer rollback, heartbeat throttle, idle_ttl/clock‑jump truths, scoped hello, nested‑UoW effects, owned keys) — taskv2 tests 45/45 | ✅ `3054b52a … fa38412a` |
| **M2** | `submit/block/handoff`, `review post`, strict‑AND gate + user approval + oscillation guard, `task fetch/comment`, legacy create/update/publish/fleet verbs inside the UoW, facets write/read (verbatim) with `vcs` (bridge‑enriched) and `verify` (hub‑written from Run sessions), verify‑gated submit, brief validation + ctl flags, `CreateTaskModal` brief fields, shared facet fixtures (Odin + TS), `scripts/task-v2-smoke.sh` | 🔧 in progress |
| **M3** | Full `TASK.md` context pack (bridge decrypts, caps after decryption), skills/AGENTS.md rewrite, mechanical chain summary (+ `chain summary set`), fleet placement editor, `runtime`/`artifacts`/`findings` facets, commit‑diff route + file‑at, independent re‑verify in an ephemeral worktree, **auto‑submit**, coordinator `chain propose` + attention lines, metrics. Ticket chains complete → mergeable | ☐ |
| **M3b** | `workflow.v1` + snapshot, materialiser (`needs`/`parallel`/`for_each`, stage completeness, explicit edges, idempotent), gates, `workflow.*` verbs, `--cascade` + carry‑forward, built‑in JSON templates, `on_output: start_workflow` | ☐ |
| **M4** | Ticket board, pipeline view, shared detail (Your review, Placement, Changes, Verify, Output), timeline; delete old hooks (`useSetTaskStatus`, `useVote`, `useNudge`, `task.status`/`assignee_ref` reads) | ☐ |
| **M5** | Remove remaining v1 code/docs, Grafana panel, user‑defined workflow definitions UI, per‑lease worktrees (lifts one‑work‑lease‑per‑directory), optional token/cost accounting, free repo results in the engine (memory tracker clean) | ☐ |

Known gaps at the M2 line: agents receive the skeleton pack (brief + previous handoff) rather than the full `TASK.md`; no auto‑submit; no workflow chains; the board still renders old components minus the deleted hooks (cards show the new 5 states via the projection); `src/prompts/bootstrap_profile_guidance.md` still mentions removed verbs (M3 skill rewrite).

---

## 9. Operations

- Deploy hub, bridge and `ham-ctl` together (migration 087 is one‑way: votes dropped, legacy status columns removed; the twin makes re‑runs idempotent).
- Metrics: `heimdall_task_lease_active{kind}`, `heimdall_task_lease_expired_total{reason}`, `heimdall_task_matcher_runs_total{trigger}`, `heimdall_task_timers_armed`, `heimdall_task_verify_total{result}` (M2). Never labelled with ids.
- Tests: `odin test src/hub/service/taskv2 -collection:odin_test=src -extra-linker-flags:-L<sqlite lib dir> -out:$HOME/.cache/heimdall-tests/<unique>`; `tests/no_reconcile_symbol_test.sh`; smoke `scripts/task-v2-smoke.sh` (M2) on loopback ports 18xxx.
- Design history and reviews: `~/.gemini/jetski/brain/923cc121-786a-484a-8992-caaab6dcf090/{task_system_v2_design, task_v2_implementation_plan, task_v2_plan_review, task_v2_m01_code_review, workflow_example, tickets_vs_workflow}.md`.
