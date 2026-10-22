#!/usr/bin/env bash
# Scoped verification for the call/write-reduction integration branch: ancestry of
# the reviewed task 1-4 commits (by patch-id, since they were cherry-picked onto
# ae2728d7), the migration order 102,103,104, then each task's own scoped checks
# (Odin tests, baseline replay, index harness, UI suites, hub build) re-run in THIS
# worktree.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== ancestry: base ae2728d7 and the reviewed commits by patch-id"
BASE=ae2728d7
git merge-base --is-ancestor "$BASE" HEAD
# baseline ff7507fb cfe5316d; task 2 da60cae2 7a2d5aa4; task 3 65419377 1b4546e0 a5bb14fb;
# task 4 0520e022 47c4bb32 (0520e022 needed a migration-order merge, so its files are checked against the task-4 tip 47c4bb32
# by file content below instead of patch-id).
have=$(git log --format=%H "$BASE"..HEAD | xargs -n1 sh -c 'git show "$0" | git patch-id --stable' | cut -d' ' -f1)
for c in ff7507fb cfe5316d da60cae2 7a2d5aa4 65419377 1b4546e0 a5bb14fb 47c4bb32; do
	pid=$(git show "$c" | git patch-id --stable | cut -d' ' -f1)
	echo "$have" | grep -qx "$pid" || { echo "missing reviewed commit $c"; exit 1; }
done
git diff --quiet 47c4bb32 HEAD -- src/hub/repository/sqlite/migrations/104_full_scan_indexes.sql \
	src/hub/repository/sqlite/full_scan_indexes_test.odin tests/sqlite_index_eval.odin
grep -A3 '"102_drop_bridge_enrollments.sql",' src/hub/repository/sqlite/migrations.odin \
	| grep -q '"104_full_scan_indexes.sql"'
grep -q 'migration_order :: \[107\]string' src/hub/repository/sqlite/migrations.odin
echo "ancestry OK"

echo "== REQ-CACHE: main-conn cache_size pragma (per connection, mmap off) + wiring uses it"
mkdir -p "$HOME/.cache/heimdall-tests"
cache_out=$(mktemp -d "$HOME/.cache/heimdall-tests/cri-cache.XXXXXX")
trap 'rm -rf "$cache_out"' EXIT
nix develop -c odin build src/hub/repository/sqlite -build-mode:test -collection:odin_test=src \
	-define:ODIN_TEST_NAMES=sqlite.test_main_conn_cache_size_is_per_connection -define:ODIN_TEST_FANCY=false -out:"$cache_out/sqlite_cache"
nix develop -c "$cache_out/sqlite_cache"
grep -q 'sqlite.exec(&graph.db, sqlite.MAIN_CONN_CACHE_SIZE_PRAGMA)' src/hub/app/wiring.odin
if git grep -nE 'PRAGMA mmap_size *=' -- 'src/hub/*.odin' ':!*_test.odin'; then echo "mmap_size must stay off"; exit 1; fi
echo "cache pragma OK"

echo "== task 4: sqlite tests, index harness, baseline replay, hub build"
bash verify-sqlite-index.sh
echo "== task 2: hot-path write tests, baseline replay, hub build"
bash verify-hotpath-writes.sh
echo "== task 3: backend + UI fetch-dedup suites"
bash verify-api-fetch-dedup.sh
echo "verify-integration: ALL PASS"
