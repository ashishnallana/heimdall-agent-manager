#!/usr/bin/env bash
# Task System v2 invariant: there is NO manual reconcile of task chains — no
# engine proc, no HTTP route, no ctl verb, no bridge agent route, no UI hook.
# State is a fold over task_events and every timer is armed by the event that
# makes it relevant (see docs/task_system_v2 design). This test keeps the
# symbols dead: it fails if any of them reappears anywhere under src/.
#
# Run from the repository root: tests/no_reconcile_symbol_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='reconcile_chain\b|reconcile_task_chain\b|/reconcile\b|reconcileTaskChain|ReconcileTaskChain|task_chain\.reconcile|task-chain reconcile|recompute_chain_promotions|recompute_promotions_for_chain_id'

if matches=$(git grep -n -E "$pattern" -- src ':!src/hub/repository/sqlite/fts_repair.odin' 2>/dev/null); then
	if [ -n "$matches" ]; then
		echo "FAIL: manual task-chain reconcile symbols reappeared under src/:" >&2
		echo "$matches" >&2
		exit 1
	fi
fi
echo "ok: no task-chain reconcile symbols under src/"
