# Placement attention and recovery

REQ-PLACE-2/3 builds on [placement failure snapshots](task-placement-failures.md).
The Hub projects one `task_placement` provider card with kind `task` and reason
`placement` per task/attempt: `crd_placement_<task_id>_<attempt_no>`. This ID is
separate from the existing review/question/Start agent card. Resolved groups
and old attempts retire independently. Existing discard/snooze semantics apply:
an unchanged observation stays dismissed or snoozed; a changed group wakes it.

`details.targets` contains each failure verbatim, a typed observation `guard`,
bridge and identity action names/labels, explicit scope labels, and
`affected_task_ids`. The latter lists ready/review work potentially using that
fleet row, including work whose existing leases retain their original placement.
`action_refs` identifies the task, chain and recovery endpoint. Generic card
operations are empty because these controls need an owner selection; clients
must use the typed recovery endpoint, not construct arbitrary card operations.

## Endpoints

All three POST routes use the same native mutation and accept owner user
authentication only (including native OIDC). Agent/coordinator instance tokens
do not authorize recovery.

```text
/api/v1/tasks/{task_id}/placement-recovery
/api/v1/task-chains/{chain_id}/tasks/{task_id}/placement-recovery
/api/v1/cards/{card_id}/placement-recovery
```

Example worker bridge repair (copy observation fields from the target guard):

```json
{
  "expected_attempt": 0,
  "phase": "work",
  "agent_id": "agt_worker",
  "role": "worker",
  "fingerprint": "<observed failure fingerprint>",
  "configuration": "<observed configuration hash>",
  "expected_assignment": "agt_worker",
  "action": "change_bridge",
  "scope": "ticket",
  "bridge_id": "brg_destination"
}
```

Attempt zero and an empty `expected_assignment` are valid. Both fields must
still be present. The named/role review guard uses the failed durable agent as
`expected_assignment`. Return values use the normal API envelope with the fresh
task, including any actionable post-commit launch failure. A successful config
repair does not imply a successful process launch. On 409, refresh attention
and select the new target; do not replay a guard from an earlier observation.

| Action | Scope | Effect |
| --- | --- | --- |
| Worker `change_bridge` | `ticket` | Changes only the ticket's bridge pin |
| Reviewer `change_bridge` | `chain_fleet` | Changes only that agent's fleet bridge; applies to future grants across the chain |
| `change_assignee` | `ticket` | Changes only the brief's durable assignee |
| Named `change_reviewer` | `ticket` | Replaces only the failed named reviewer |

Identity repair supplies `replacement_agent_id`. The replacement must be an
owned active durable `agt_` identity with an eligible unpaused fleet role and
valid effective placement. An instance ID, foreign/archived identity, author
reviewing its own work, or already-named replacement is rejected. Configure the
fleet first if the intended replacement has no eligible row. Native bridge,
agent support, enrollment, ownership, provider/profile/model and chain workspace
validation runs before a change is saved. Host-local paths are never copied.

Role reviewers follow the existing AND-over-fleet-role-holders model. Their
identity action is `configure_fleet`, with the failure's chain/role identifying
the configuration destination. The API refuses to disguise a role edit as a
task-local reviewer assignment or remove the role requirement. A pull-only solo
coordinator uses its instance placement, so its bridge action is
`configure_coordinator`; pinning its ticket would be ineffective and is refused.
An eligible ordinary worker can instead be selected with `change_assignee`.
Workflow-generated task placement remains under native workflow controls.

## Transaction and scheduling behavior

The native engine opens one UoW, re-reads the owner/task/current attempt and
assignment, and recollects current placement failures. Phase/agent/role,
fingerprint and configuration must all match inside the transaction; a stale
stored facet cannot authorize a write. The card route also binds its attempt ID.
Target live leases are rejected with checkpoint/hold guidance. Fleet bridge
edits preserve already-granted leases on other tasks. Unrelated live reviews,
roles, named reviewers, user-approval requirements and valid verdicts survive.

The mutation records an `updated` audit event with action, scope, failed target,
fingerprint and destination/replacement. Named changes use native review
re-gating. Native matching/reconciliation runs in the same UoW; bridge wakes,
card notification and resource publication flush after commit. Duplicate or
stale operations produce no extra audit event or launch.

Recovery deliberately avoids the fleet retry helper that resets idle instances.
User-stop flags remain intact and require the existing explicit Start consent.
Failed launches retain normal Start agent attention and do not consume the
worker's attempt budget. Reconnects and other native lifecycle hooks reconcile
placement facets and both attention card types. Periodic reconciliation also
discovers current placement facets for ready workers and agent-only reviews,
and retires old groups even if a notification was missed.

## Verification

All commands ran from the task worktree using Nix Odin. No live production
task mutations were used for implementation tests.

```bash
nix develop --command odin test src/hub/service/card -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/recovery-card-final-$$ -define:ODIN_TEST_THREADS=4
nix develop --command odin test src/hub/repository/sqlite -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/recovery-sqlite-full-$$ -define:ODIN_TEST_THREADS=4
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/recovery-engine-full-$$ -define:ODIN_TEST_THREADS=4
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/recovery-http-final-$$ -define:ODIN_TEST_THREADS=4 -define:ODIN_TEST_NAMES=http.test_placement_recovery_http_authority_guards_and_scope,http.test_recheck_http_routes_auth_and_result
nix develop --command odin build src/hub -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/recovery-hub-final-$$
```

- Full card suite: **35/35 pass**. After final card metadata refinements, the
  two new placement tests plus the adjacent Start consent/retry test pass again.
- Full SQLite suite: **181/181 pass**.
- Full taskv2 suite: **170/174 pass**, including all six new recovery tests.
  Final targeted runs of the six tests and the added live-lease guidance
  assertion also pass. The four full-suite failures exactly match those already
  independently established at the dependency baseline:

  ```text
  taskv2.test_clock_jump_extension_only_when_jump_detected
  taskv2.test_lease_next_after_expiry_409
  taskv2.test_d1_verify_waiting_task_gets_fresh_review_after_migration
  taskv2.test_fleet_delete_reevaluates_gate
  ```

- Focused HTTP suite: **2/2 pass**, including the new task/card recovery test
  and the adjacent recheck test updated for first-observation persistence.
- Hub build and `git diff --check`: **pass**.

The new real-SQLite regressions cover grouped independent targets, current
attempt retirement, missed-notification reconciliation, preserved question and
Start attention, snooze invalidation, owner/token/path/foreign bridge guards,
assignment/fingerprint/configuration races, duplicate recovery, concurrent
review targets, active leases, targeted named replacement with unrelated live
reviews/verdicts/user approval, workflow restrictions, workspace/provider/owned
identity eligibility, explicit-stop consent and post-commit launch failure.

UI tests and UI build are outside this backend ticket; no UI source changed.
The full HTTP suite was not required for the narrow typed endpoint additions;
the touched handlers compile in the Hub build and their focused regressions
pass. The repository references `scripts/install-git-hooks.sh`, but the script
is absent in this checkout as already recorded by the dependency task. No hook
bypass flags were used.
