#!/usr/bin/env bash
# Scoped verification for publishing the reviewed communication stack on top of the
# latest origin/main, all in THIS worktree. Covers both sides of the merge:
#   - ancestry: HEAD contains the remote base and the reviewed stack tip (by commit id,
#     no local branch refs), and upstream-only files are byte-identical to the base;
#   - communication stack: producer events, user-WS transport, GET /agents summary view,
#     request-count/perf/mounted hidden-pane suites (incl. the render->effect race);
#   - upstream since 244bedbf: task detail reviews wire + bridge_id wire tests, taskv2
#     agent-not-running, the card package (card_service.odin changed on both sides) and
#     the review-votes / task v2 UI suites (TaskDetails.tsx changed on both sides);
#   - typecheck and production vite build.
set -euo pipefail
cd "$(dirname "$0")"

# origin/main after `git fetch origin` (release v0.4.25) and the reviewed stack tip
# (refresh/catchup-fix final head).
REMOTE_BASE=1e1a6b96814cc4ebbd55f2b9cc6ba2586efe309a
STACK_TIP=2b053d803e143e91129d4963f0b268c3120e3141

echo "== ancestry =="
git merge-base --is-ancestor "$REMOTE_BASE" HEAD || { echo "HEAD does not contain remote base $REMOTE_BASE"; exit 1; }
git merge-base --is-ancestor "$STACK_TIP" HEAD || { echo "HEAD does not contain stack tip $STACK_TIP"; exit 1; }
# Files upstream changed that the stack never touched must be exactly upstream's.
UPSTREAM_ONLY="AGENTS.md flake.nix package.json scripts/check-npm-deps-hash.sh scripts/install-git-hooks.sh src/contracts/protocol.odin src/hub/service/taskv2/agent_not_running_test.odin src/hub/service/taskv2/dispatch.odin src/hub/transport/http/task_bridge_id_wire_test.odin src/ui/api/taskWire.ts src/ui/components/tasks/ReviewVoteMark.tsx src/ui/components/tasks/TaskCard.tsx src/ui/components/tasks/taskActions.ts tests/ui_task_v2_review_votes_test.ts"
# shellcheck disable=SC2086
if ! git diff --quiet "$REMOTE_BASE" HEAD -- $UPSTREAM_ONLY; then
  echo "upstream-only files differ from $REMOTE_BASE:"; git diff --stat "$REMOTE_BASE" HEAD -- $UPSTREAM_ONLY; exit 1
fi
echo "ok (contains $REMOTE_BASE and $STACK_TIP; upstream-only files unchanged)"

echo "== backend: resource refresh events (refresh_producers) =="
bash ./verify-refresh-events.sh

echo "== backend + ui: user WS transport (refresh_transport) =="
bash ./verify-refresh-transport.sh

OUT="$HOME/.cache/heimdall-tests/refresh-publish"
mkdir -p "$OUT"
echo "== backend: GET /agents?view=summary, upstream wire/taskv2 tests, card package =="
nix develop -c bash -c "
  set -euo pipefail
  odin build src/hub -build-mode:test -collection:odin_test=src -out:'$OUT/hub' \
    -define:ODIN_TEST_NAMES=main.test_agents_list_summary_view_is_opt_in
  timeout 300 '$OUT/hub'

  odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:'$OUT/http' \
    -define:ODIN_TEST_NAMES=http.test_task_bridge_id_from_body_absent_present_empty,http.test_write_task_json_always_emits_bridge_id,http.test_cookie_task_bridge_id_create_and_patch,http.test_agent_action_task_bridge_id_create_and_update,http.test_write_task_json_and_detail_emit_v2_state,http.test_write_task_detail_emits_current_attempt_reviews
  timeout 300 '$OUT/http'

  odin build src/hub/service/taskv2 -build-mode:test -collection:odin_test=src -out:'$OUT/taskv2' \
    -define:ODIN_TEST_NAMES=taskv2.test_agent_not_running_offline_start_failure_retry_and_dead_holder,taskv2.test_agent_not_running_capacity_is_queueing_and_failed_ready_is_blocked,taskv2.test_agent_not_running_unresolvable_provider_and_model,taskv2.test_agent_not_running_solo_start_launches_only_on_user_action
  timeout 300 '$OUT/taskv2'

  odin build src/hub/service/card -build-mode:test -collection:odin_test=src -out:'$OUT/card'
  timeout 300 '$OUT/card'
"

if [ ! -d node_modules ]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi

echo "== ui: typecheck =="
timeout 600 npm run typecheck

echo "== ui: production build =="
timeout 900 npx vite build --logLevel warn

run() { timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test "$@"; }

echo "== ui: request-count regressions (integration, trim) =="
run tests/ui_refresh_integration_test.ts
run tests/ui_refresh_request_reduction_test.ts

echo "== ui: performance and mounted hidden pane / catch-up =="
run tests/ui_refresh_performance_test.ts
run tests/ui_pane_deferral_mounted_test.ts

echo "== ui: other user-WS flush consumers =="
run tests/ui_attention_deck_test.ts tests/ui_notification_funnel_integration_test.ts tests/ui_pane_visibility_gate_test.ts
run tests/search_title_cache_test.ts

echo "== ui: task v2 views (TaskDetails changed upstream and in the stack) =="
run tests/ui_task_v2_review_votes_test.ts tests/ui_task_v2_board_test.ts tests/ui_task_v2_actions_test.ts tests/ui_task_v2_names_test.ts

echo "verify-refresh-publish: ALL PASS"
