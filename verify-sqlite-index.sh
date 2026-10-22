#!/usr/bin/env bash
# Scoped verification for REQ-INDEX (migration 105 full-scan indexes).
# 1. migration 105 fresh/upgrade/idempotence/query-plan tests plus the existing
#    migration, shell-session and taskchain repository tests (sqlite package, scoped);
# 2. the index-evaluation harness at task-1 scale (asserts identical results with and
#    without every candidate index, and nonempty retention deletes);
# 3. the task-1 call/write baseline replay;
# 4. the hub build.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p "$HOME/.cache/heimdall-tests"
scratch=$(mktemp -d "$HOME/.cache/heimdall-tests/sqlite-index.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

pkg=src/hub/repository/sqlite
names=$(grep -h -A1 '^@(test)' "$pkg/full_scan_indexes_test.odin" "$pkg/migrations_test.odin" \
	"$pkg/shell_session_repo_test.odin" "$pkg/taskchain_repo_test.odin" \
	| grep -oE '^[a-zA-Z0-9_]+ ::' | sed -E 's/ ::$//; s/^/sqlite./' | paste -sd, -)
echo "== sqlite tests: $(echo "$names" | tr ',' '\n' | wc -l) tests"
nix develop -c odin build "$pkg" -build-mode:test -collection:odin_test=src \
	-define:ODIN_TEST_NAMES="$names" -define:ODIN_TEST_FANCY=false -out:"$scratch/sqlite_tests"
nix develop -c "$scratch/sqlite_tests"

echo "== index evaluation harness (t1 scale)"
nix develop -c odin build tests/sqlite_index_eval.odin -file -collection:odin_test=src -out:"$scratch/index_eval"
nix develop -c "$scratch/index_eval" "$scratch/index-eval.db" t1 > "$scratch/index-eval.txt"
grep -q '^## Shipped migration 105' "$scratch/index-eval.txt"
echo "harness completed; result-equivalence assertions passed"

echo "== task-1 baseline replay"
bash verify-baseline.sh > "$scratch/baseline.txt"
echo "baseline replay passed"

echo "== hub build"
nix develop -c odin build src/hub -collection:odin_test=src -out:"$scratch/hub"
echo "Hub build succeeded."
