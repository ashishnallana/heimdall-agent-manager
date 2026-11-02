# Native placement-failure snapshots

Implements REQ-PLACE-1 and the engine reconciliation portion of REQ-PLACE-3 from
[the approved plan](../plans/placement-attention-recovery.md). Cards, recovery APIs
and UI controls are separate follow-on work.

## Storage and reads

The existing `task_attempt_facets` table already supplies transactional,
owner-scoped storage, a unique `(task_id, attempt_no, kind)` key, versions and
post-commit facet notifications. The business-event fold has one `blocked_on`
slot and cannot represent concurrent reviewer placement failures safely. The
implementation therefore uses a Hub-written `placement` facet rather than a
migration or a new task business event.

Read the task under its owner, then read `FACET_PLACEMENT` for **that task's
current `attempt_no`**. Native consumers can use `get_facet` or the repository's
`taskchain_list_facets_by_task` with the task owner and select the same key.
The existing fetch reference is `facet:<task_id>:<attempt_no>:placement`.
Attempt **0** is valid and stores failures before the first work grant. No
`task_attempts` row or work budget is created just to record placement.

The facet body is:

```json
{
  "schema_version": 1,
  "failures": [
    {
      "phase": "review",
      "agent_id": "agt_reviewer",
      "role": "security",
      "bridge_id": "brg_effective",
      "directory_id": "dir_effective",
      "source": "fleet",
      "reason": "bridge_offline",
      "message": "placement bridge is offline",
      "provider": "claude",
      "model": "configured-model",
      "provider_profile": "",
      "configuration": "<sha256 hex>",
      "fingerprint": "<sha256 hex>"
    }
  ]
}
```

A missing facet or an empty `failures` array means no current placement failure.
Old-attempt facets remain history; never aggregate them into current attention.
A first work grant advances attempt 0 to 1, so the old snapshot immediately stops
being current. A review grant keeps its attempt and removes only targets no
longer owed. A snapshot that previously contained failures is rewritten to an
empty array when resolved in the same attempt. No empty facet is created when
none existed.

Entries are sorted by `(phase, agent_id, role)`. Their identity is the enclosing
task/attempt plus those three fields. `phase` is `work` or `review`; `role` is
`worker`, `named`, or the actual native review role. An agent owing named,
reviewer and security requirements has three entries for the same unavailable
placement, matching the native review pairs. A missing worker identity may be
empty when the chain has no worker row at all; a missing named reviewer retains
its durable agent ID.

`source` is `task`, `fleet`, `directory`, `coordinator` or `unresolved`.
Worker resolution keeps task pin → fleet → chain directory → coordinator
precedence. Review resolution excludes the task pin. Unresolvable targets use
empty bridge/directory IDs. Provider/model/profile fields carry the selected
placement configuration and may be empty when inherited; they are not proof
that a provider is currently runnable.

## Stable causes and guards

| Reason | Meaning |
| --- | --- |
| `placement_missing` | No effective bridge can be resolved |
| `bridge_missing` | The configured bridge record cannot be found |
| `bridge_offline` | The effective bridge is offline |
| `bridge_ineligible` | Foreign, revoked, pending enrollment, plan-disabled bridge, or disabled agent support on that bridge |
| `workspace_missing` | The chain uses directories but has no mapping on this bridge |
| `provider_ineligible` | Native provider/profile/model validation rejects the placement |
| `worker_missing` | No worker fleet row matches the assignment |
| `reviewer_missing` | An owed named reviewer has no fleet row |

Messages are explanatory; consumers should branch on `reason`.
`configuration` hashes the canonical native configuration inputs: task/attempt,
phase/agent/role, effective placement and source, brief and task pin, fleet
placement/provider/profile/model map/roles/pause/capacity/update version, and the
selected directory path/update version. `fingerprint` hashes the canonical
entry including that configuration hash and cause/message, before adding the
fingerprint field itself. Both use SHA256 hexadecimal strings.

Neither hash includes wall-clock time, task heartbeat/update time, or snapshot
write time. Identical snapshots do not write or bump facet `v`; elapsed time
alone does not invalidate a target. Relevant configuration changes and changes
of effective target/cause do invalidate it. These hashes identify the observed
failure, not authorization: future recovery operations must still authenticate,
re-read and validate ownership, target requirements, configuration and leases
inside their native unit of work.

## Lifecycle and exclusions

`placement_problem` is shared by wake dispatch and snapshot collection so an
ineligible placement is recorded before JIT/grant. The read-only collector never
launches, resets, stops or releases an instance and never changes reviews or task
business state. Placement-only failures keep workers ready and reviews in review.
Existing `agent_not_running` process failures and explicit Start agent consent
remain on their existing path; they are not duplicated as placement entries.
Legacy stored infrastructure blocks retain their existing recovery semantics.

Collection excludes held/inactive/draft/gate tasks, work dependencies, workflow
stage parallelism, directory serialization, fleet capacity, paused roles,
pending runtime operations and transient provider backoff. A usable queued
alternative suppresses placement attention for an unassigned worker.
A live review lease or completed approval excludes only that reviewer's owed
pairs, never another reviewer's failures.

Reconciliation uses fresh durable state after matching, inline grants, task and
fleet changes, review/lease transitions, re-check and chain close. Bridge hello
uses the native matcher; bridge disconnect also calls the read-only placement
hook because an idle unavailable bridge may have no terminal instance callback.
The transport invokes this after its existing connection-generation guard and
outside the runtime state lock. Writes, facet notifications and attention
reprojection are deferred through the native unit of work. Facet-only re-check
changes count as changes and commit, including diagnosis of another reviewer
while an unrelated review lease is live.

Normal instance selection still owns retry timer arming. The diagnostic retry
check must not replace `pick_instance` on dispatch paths: doing so skips the
long-backoff deadline timer.

## Validation

Baseline commit: `0da7ccc12de528db47046b33541e1770ceb4b62b`.

- Eight new SQLite-backed engine regressions cover attempt 0, stable versions
  across elapsed time, current-attempt retirement, parallel multi-role failures,
  preserved live leases/verdicts, partial fleet repair, named requirement edits,
  missing/ineligible/workspace placement, holds, dependencies, capacity, pause,
  backoff, transaction rollback, database/service reload and reconnect recovery.
- The focused native run includes those eight tests and sixteen existing
  dispatch, consent, retry, lease, re-check and facet tests: **24/24 pass**.
- Full `src/hub/repository/sqlite` suite: **181/181 pass**.
- Hub build with Nix Odin and `-collection:odin_test=src`: **pass**.
- Full `src/hub/service/taskv2` suite: **164/168 pass**. The same four failures
  reproduce in the unmodified baseline, which passes 156/160:

```text
taskv2.test_clock_jump_extension_only_when_jump_detected
taskv2.test_lease_next_after_expiry_409
taskv2.test_d1_verify_waiting_task_gets_fresh_review_after_migration
taskv2.test_fleet_delete_reevaluates_gate
```

The baseline was tested in a detached checkout at the commit above with the same
Nix toolchain and thread count. No unrelated baseline fixes are included.
Exact broad commands (all from the corresponding checkout):

```bash
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/placement-final-full-$$ -define:ODIN_TEST_THREADS=4
nix develop --command odin test src/hub/repository/sqlite -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/placement-sqlite-$$ -define:ODIN_TEST_THREADS=4
nix develop --command odin build src/hub -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/placement-hub-final-$$
```

The baseline full-suite command, run from the detached baseline checkout, was:

```bash
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/placement-baseline-$$ -define:ODIN_TEST_THREADS=4
```
