#!/usr/bin/env bash
# Scoped verification for call-reduction-rebased: the reviewed call/write-reduction
# work (integration branch 448ca6e5, base ae2728d7) ported onto origin/main 483f5b43,
# with our migrations renumbered after main's 103_plan_enforcement.sql
# (103_guard_chat_fts_updates -> 104, 104_full_scan_indexes -> 105) and the
# user-approved 3600 s vault last_seen throttle. Union of verify-integration.sh:
# ancestry, REQ-CACHE, then each task's scoped checks, re-run in THIS worktree.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BASE=483f5b43197c9d21f75572fae732f69608fe90e6 # origin/main when the port started
INTEGRATION=448ca6e505320af3ffc70cb62985c9eb9a3c0781
INTEGRATION_BASE=ae2728d7
MIG=src/hub/repository/sqlite/migrations.odin

echo "== ancestry: base $BASE and the reviewed commits"
git merge-base --is-ancestor "$BASE" HEAD
have=$(git log --format=%H "$BASE"..HEAD | xargs -n1 sh -c 'git show "$0" | git patch-id --stable' | cut -d' ' -f1)
# Unchanged by the port, so matched by patch-id: baseline ff7507fb cfe5316d; task 3
# 65419377 1b4546e0 a5bb14fb; task 4 47c4bb32; task 5 (integration) 448ca6e5.
for c in ff7507fb cfe5316d 65419377 1b4546e0 a5bb14fb 47c4bb32 "$INTEGRATION"; do
	pid=$(git show "$c" | git patch-id --stable | cut -d' ' -f1)
	echo "$have" | grep -qx "$pid" || { echo "missing reviewed commit $c"; exit 1; }
done
echo "patch-id: 7 reviewed commits present"

# Adapted (no patch-id match): task 2 da60cae2 + 7a2d5aa4 and task 4 0520e022 met
# main's 103_plan_enforcement in migrations.odin, and the renumber commit edits
# their files. Instead, every file the integration branch changed must equal its
# integration content after the renumber rewrite (docs are compared verbatim), and
# migrations.odin must add exactly the integration lines, renumbered.
THROTTLE=$(git log --format=%H --grep='^Raise the vault last_seen throttle to one hour' "$BASE"..HEAD)
[ -n "$THROTTLE" ] && [ "$(echo "$THROTTLE" | wc -l)" -eq 1 ]
# The throttle commit is the only approved behaviour change; it touches only these.
diff <(git diff --name-only "$THROTTLE^" "$THROTTLE" | sort) <(printf '%s\n' \
	src/hub/domain/vault_directory.odin \
	src/hub/repository/sqlite/vault_directory_repo_sqlite.odin \
	src/hub/transport/http/vault_directory_handlers.odin \
	tests/hotpath_writes_test.odin | sort)
# Files whose current content predates the throttle commit compare at its parent.
throttle_files=$(git diff --name-only "$THROTTLE^" "$THROTTLE")
renumber='s/104_full_scan_indexes/105_full_scan_indexes/g; s/MIGRATION_104_FULL/MIGRATION_105_FULL/g; s/103_guard_chat_fts_updates/104_guard_chat_fts_updates/g; s/MIGRATION_103_GUARD/MIGRATION_104_GUARD/g; s/before_103/before_104/g; s/attach 103 triggers/attach 104 triggers/; s/migration 104/migration 105/g; s/pre-104/pre-105/g; s/^-- 104:/-- 105:/'
# Files main also changed since ae2728d7 (wiring.odin, shells.ts, migrations.odin)
# cannot match whole; their added/removed lines must match instead.
overlap=$(comm -12 <(git diff --name-only "$INTEGRATION_BASE" "$BASE" | sort) <(git diff --name-only "$INTEGRATION_BASE" "$INTEGRATION" | sort))
changed_lines() { git diff -U0 "$1" "$2" -- "$3" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -v '^[+-]migration_order :: ' || true; }
checked=0
while read -r old; do
	case "$old" in
	verify-integration.sh | docs/call-reduction-integrated-results.md) continue ;;
	esac
	if echo "$overlap" | grep -qx "$old"; then
		[ "$old" = "$MIG" ] && continue
		diff <(changed_lines "$INTEGRATION_BASE" "$INTEGRATION" "$old" | sort) <(changed_lines "$BASE" HEAD "$old" | sort) \
			|| { echo "changed-line drift in $old"; exit 1; }
		checked=$((checked + 1))
		continue
	fi
	new=$(echo "$old" | sed 's/103_guard_chat_fts_updates/104_guard_chat_fts_updates/; s/104_full_scan_indexes/105_full_scan_indexes/')
	rev=HEAD
	echo "$throttle_files" | grep -qx "$new" && rev="$THROTTLE^"
	case "$old" in
	docs/*) rewrite='' ;;
	*/full_scan_indexes_test.odin) rewrite="$renumber; s/104/105/g" ;;
	*) rewrite="$renumber" ;;
	esac
	diff <(git show "$INTEGRATION:$old" | sed "$rewrite") <(git show "$rev:$new") >/dev/null \
		|| { echo "content drift in $new (vs $INTEGRATION:$old)"; exit 1; }
	checked=$((checked + 1))
done < <(git diff --name-only "$INTEGRATION_BASE" "$INTEGRATION")
echo "content: $checked files match the integration branch after the renumber (overlap files by changed lines)"
diff <(changed_lines "$INTEGRATION_BASE" "$INTEGRATION" "$MIG" | sed "$renumber; s|^+// 104: live-by-kind|+// 105: live-by-kind|; s/so 103 also requires/so 104 also requires/" | sort) \
	<(changed_lines "$BASE" HEAD "$MIG" | grep -vE '^\+// (104: chat FTS update triggers fire only|no longer rewrites the FTS rows)' | sort)
echo "migrations.odin: integration lines present, renumbered"

echo "== migration numbering after main's tip"
grep -A4 '"102_drop_bridge_enrollments.sql",' "$MIG" | tr -d '\t' | paste -sd' ' \
	| grep -qx '"102_drop_bridge_enrollments.sql", "103_plan_enforcement.sql", "104_guard_chat_fts_updates.sql", "105_full_scan_indexes.sql", }'
grep -q 'migration_order :: \[108\]string' "$MIG"
entries=$(awk '/^migration_order ::/{on=1;next} on&&/^}/{exit} on&&/"/{n++} END{print n}' "$MIG")
[ "$entries" -eq 108 ] || { echo "migration_order has $entries entries, declared 108"; exit 1; }
grep -q 'if name == "104_guard_chat_fts_updates.sql" do return strings.clone(MIGRATION_104_GUARD_CHAT_FTS_UPDATES)' "$MIG"
grep -q 'if name == "105_full_scan_indexes.sql" do return strings.clone(MIGRATION_105_FULL_SCAN_INDEXES)' "$MIG"
dups=$(ls src/hub/repository/sqlite/migrations | grep -oE '^1[0-9]{2}' | sort | uniq -d)
[ -z "$dups" ] || { echo "migration number reused: $dups"; exit 1; }
if git grep -n '103_guard_chat_fts_updates\|104_full_scan_indexes\|MIGRATION_103_GUARD\|MIGRATION_104_FULL' -- src tests tools '*.sh' ':!verify-rebased.sh'; then
	echo "stale migration name"; exit 1
fi
echo "numbering OK (104 guard, 105 indexes, 108 entries, no reuse)"

echo "== vault last_seen throttle: one named 3600 s constant"
grep -q '^VAULT_LAST_SEEN_THROTTLE_SECONDS :: 3600$' src/hub/repository/sqlite/vault_directory_repo_sqlite.odin
if grep -nE 'unixepoch\(\?1\) - [0-9]' src/hub/repository/sqlite/vault_directory_repo_sqlite.odin; then echo "literal throttle"; exit 1; fi
echo "throttle OK"

mkdir -p "$HOME/.cache/heimdall-tests"
scratch=$(mktemp -d "$HOME/.cache/heimdall-tests/rebased.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

echo "== rebased upgrade tests + main's plan-enforcement migration tests"
pkg=src/hub/repository/sqlite
names=$(grep -h -A1 '^@(test)' "$pkg/rebased_migration_order_test.odin" "$pkg/billing_repo_test.odin" \
	| grep -oE '^[a-zA-Z0-9_]+ ::' | sed -E 's/ ::$//; s/^/sqlite./' | paste -sd, -)
echo "$(echo "$names" | tr ',' '\n' | wc -l) tests"
nix develop -c odin build "$pkg" -build-mode:test -collection:odin_test=src \
	-define:ODIN_TEST_NAMES="$names" -define:ODIN_TEST_FANCY=false -out:"$scratch/rebased_sqlite"
nix develop -c "$scratch/rebased_sqlite"

echo "== REQ-CACHE: main-conn cache_size pragma (per connection, mmap off) + wiring uses it"
nix develop -c odin build "$pkg" -build-mode:test -collection:odin_test=src \
	-define:ODIN_TEST_NAMES=sqlite.test_main_conn_cache_size_is_per_connection -define:ODIN_TEST_FANCY=false -out:"$scratch/sqlite_cache"
nix develop -c "$scratch/sqlite_cache"
grep -q 'sqlite.exec(&graph.db, sqlite.MAIN_CONN_CACHE_SIZE_PRAGMA)' src/hub/app/wiring.odin
if git grep -nE 'PRAGMA mmap_size *=' -- 'src/hub/*.odin' ':!*_test.odin'; then echo "mmap_size must stay off"; exit 1; fi
echo "cache pragma OK"

echo "== task 4: sqlite tests, index harness, baseline replay, hub build"
bash verify-sqlite-index.sh
echo "== task 2: hot-path write tests, baseline replay, hub build"
bash verify-hotpath-writes.sh
echo "== task 3: backend + UI fetch-dedup suites"
bash verify-api-fetch-dedup.sh
echo "verify-rebased: ALL PASS"
