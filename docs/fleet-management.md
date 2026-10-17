REQ-FLEET-BRIDGE-MODELS-1: Fleet launch settings are stored per chain and agent identity.
GET `/task-chains/{chainId}/fleets` and PUT
`/task-chains/{chainId}/fleets/{agentId}` include `bridge_models`, an object keyed
by bridge ID with explicit `{ "provider": "...", "model": "..." }` values.
PUT replaces this object when supplied; omitting it preserves existing bridge
selections. An empty object clears the bridge selections. Each selection must
refer to an owner-controlled bridge and an active model of a provider enabled
and present on that bridge.

REQ-FLEET-PLACEMENT-1: Task System v2 JIT provisioning uses the task's bridge pin, then the fleet row bridge_id, then the chain directory bridge, then coordinator bridge.
It selects that bridge's saved fleet settings before the role-wide provider/model. Missing
role-wide values resolve in catalog rank/ID order against active providers and
models available on the selected bridge. Explicit unavailable values fail rather
than silently selecting a replacement.

REQ-FLEET-DISPLAY-1: The fleet drawer displays concrete launch settings for each bridge and current
live instance settings for the agent identity on that bridge. Apply persists
bridge selections independently. Confirmed restarts resolve each instance's own
bridge selection and skip instances already using those settings. New-instance
only applies leave existing runtimes on their current settings.

Migration `076_fleet_bridge_models.sql` adds the durable JSON column with an empty
object default, preserving existing role-wide fleet settings.

Validation (2026-10-11):

- REQ-FLEET-RECONCILE-1 and REQ-FLEET-BRIDGE-MODELS-1: `odin test src/hub/service/taskchain -collection:odin_test=src -extra-linker-flags:-L/home/linuxbrew/.linuxbrew/lib -define:ODIN_TEST_NAMES=taskchain.test_fleet_reconcile_resolves_bridge_models_without_manual_configuration -out:/tmp/fleet-regression` — exit 0. Reconcile binds an instance without edits; a second reconcile uses the saved bridge model. Omitted settings preserve the bridge map; invalid models are rejected.
- REQ-FLEET-BRIDGE-MODELS-1: `odin test src/hub/repository/sqlite -collection:odin_test=src -extra-linker-flags:-L/home/linuxbrew/.linuxbrew/lib -define:ODIN_TEST_NAMES=sqlite.test_taskchain_fleet_sqlite_lifecycle -out:/tmp/fleet-repo-tests` — exit 0, migration and storage round trip.
- REQ-FLEET-BRIDGE-MODELS-1: `odin test src/hub/transport/http -collection:odin_test=src -extra-linker-flags:-L/home/linuxbrew/.linuxbrew/lib -define:ODIN_TEST_NAMES=http.test_fleet_bridge_models_wire_roundtrip,http.test_write_fleet_json,http.test_write_fleet_json_omitted_provider_model_empty -out:/tmp/fleet-http-tests` — exit 0, three tests, including parsing serialized fleet JSON.
- REQ-FLEET-DISPLAY-1 and REQ-FLEET-BRIDGE-MODELS-1: `node tests/fleetSelection.test.ts` — exit 0, 19 tests covering resolved settings, bridge resolution, independent bridge edits, and preserving unrendered selections.
- All three requirements: `npm run build`, direct `odin build src/hub -collection:odin_test=src -extra-linker-flags:-L/home/linuxbrew/.linuxbrew/lib -out:/tmp/ham-hub-fleet`, and `git diff --check` — exit 0. Nix is unavailable; no Nix package build or live UI interaction was performed.

The broader taskchain suite has five existing failures (38 tests, 33 passing).
`node tests/ui_fleet_actions_test.ts` has three existing capability-payload
failures (56 tests, 53 passing). The same failure names and assertions reproduced
from an unchanged `git archive HEAD src tests` checkout under
`/tmp/heimdall-fleet-baseline`. Logs are under `/tmp/fleet-*.log`.
