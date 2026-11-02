package main

// Tests for the project-scoped FS browse/CRUD helpers in fs_management.odin.
// Covers: sort ordering, cursor pagination, hidden filtering, and containment
// (path_outside_root) on list/read/move/delete/create.
//
// Odin runs @(test) procs concurrently, so these tests must NOT depend on a
// mutable shared global. We set the GLOBAL bridge_fs_root ONCE to the shared temp
// base (idempotent — every test writes the same value) and give each test its own
// unique subdirectory that is threaded through the `sandbox_root` parameter of
// every operation. This mirrors exactly how the hub's project-scoped relay calls
// these procs (project root passed per-command), and keeps tests independent.

import "core:crypto"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import base64 "core:encoding/base64"
import json "core:encoding/json"
import "core:path/filepath"
import vault "odin_test:lib/vault"

// WHY THE LENGTH ASSERTIONS BELOW ARE WRITTEN `if !testing.expect_value(...) do return`
//
// testing.expect_value does NOT abort the test; it records the failure and returns false.
// So `expect_value(t, len(xs), 1)` followed by `xs[0]` does not stop at the failed
// assertion - it proceeds to index an empty slice and takes a BOUNDS PANIC.
//
// That panic is not contained. Every test here holds bridge_test_config_mutex (declared in
// agent_token_store_test.odin) across its body via `defer sync.mutex_unlock(...)`, and the
// panic unwinds WITHOUT running that defer. The mutex is leaked held, so the next test to
// acquire it blocks forever and the whole src/bridge suite hangs without printing its
// `Finished N tests` line. That is how one empty slice silently costs every other test its
// result.
//
// Guarding with an early return keeps the defers running, so a failed expectation stays a
// clean reported failure. 2026-10-04, iss_18da1a626405e3d1; the structural problem - a
// global mutex held across panicking assertions, ~147 sites across 10 test files - is
// tracked separately and deliberately NOT reworked here.

// fs_test_base resolves (and pins) the shared temp base as the GLOBAL sandbox
// root. Idempotent across concurrent tests: they all compute + write the same
// absolute path. Per-test isolation comes from unique subdirs (see make_root).
@(private = "file")
fs_test_base :: proc() -> string {
	base := os.get_env_alloc("TMPDIR", context.allocator)
	if strings.trim_space(base) == "" do base = "/tmp"
	base = strings.trim_right(base, "/")
	if resolved, rerr := os.get_absolute_path(base, context.allocator); rerr == nil do base = resolved
	bridge_fs_root = base // global root = shared temp base (defense-in-depth ceiling)
	return base
}

// fs_test_make_root creates a unique per-test subdir under the shared base and
// returns its absolute path, to be passed as `sandbox_root` to every op.
@(private = "file")
fs_test_make_root :: proc(t: ^testing.T, tag: string) -> string {
	base := fs_test_base()
	stamp := fs_test_stamp()
	defer delete(stamp)
	root := strings.concatenate({base, "/ham_fs_test_", tag, "_", stamp})
	if err := os.make_directory_all(root); err != nil do testing.expect(t, false, "could not create temp root")
	if resolved, rerr := os.get_absolute_path(root, context.allocator); rerr == nil {
		delete(root)
		root = resolved
	}
	return root
}

@(private = "file")
fs_test_stamp :: proc() -> string {
	ns := time.to_unix_nanoseconds(time.now())
	b := strings.builder_make()
	strings.write_int(&b, int(ns % 1_000_000_000))
	return strings.to_string(b)
}

@(private = "file")
fs_test_cleanup :: proc(root: string) {
	if root != "" {
		_ = os.remove_all(root)
		delete(root)
	}
}

@(private = "file")
fs_test_seed_file :: proc(t: ^testing.T, root, rel, content: string) {
	full := strings.concatenate({root, "/", rel})
	defer delete(full)
	parent := full[:strings.last_index_byte(full, '/')]
	_ = os.make_directory_all(parent)
	testing.expect(t, os.write_entire_file_from_string(full, content) == nil, "seed file")
}

@(private = "file")
fs_test_seed_dir :: proc(t: ^testing.T, root, rel: string) {
	full := strings.concatenate({root, "/", rel})
	defer delete(full)
	testing.expect(t, os.make_directory_all(full) == nil, "seed dir")
}

// --- sort ----------------------------------------------------------------

@(test)
fs_list_sorts_dirs_first_then_name :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "sort")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "zebra.txt", "z")
	fs_test_seed_file(t, root, "apple.txt", "a")
	fs_test_seed_dir(t, root, "mango")
	fs_test_seed_dir(t, root, "banana")

	res := bridge_fs_list_dir("", true, "", 200, root)
	testing.expect(t, res.ok, "list ok")
	if !testing.expect_value(t, len(res.entries), 4) do return
	// dirs first, name asc: banana, mango, then files apple.txt, zebra.txt
	testing.expect_value(t, res.entries[0].name, "banana")
	testing.expect(t, res.entries[0].is_dir, "banana is dir")
	testing.expect_value(t, res.entries[1].name, "mango")
	testing.expect_value(t, res.entries[2].name, "apple.txt")
	testing.expect(t, !res.entries[2].is_dir, "apple is file")
	testing.expect_value(t, res.entries[3].name, "zebra.txt")
}

// --- pagination cursor ---------------------------------------------------

@(test)
fs_list_paginates_with_opaque_cursor :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "page")
	defer fs_test_cleanup(root)
	for name in ([]string{"a", "b", "c", "d", "e"}) {
		fname := strings.concatenate({name, ".txt"})
		fs_test_seed_file(t, root, fname, name)
		delete(fname)
	}
	// Page 1: limit 2 -> a,b + has_more + next_cursor
	p1 := bridge_fs_list_dir("", true, "", 2, root)
	testing.expect(t, p1.ok, "p1 ok")
	if !testing.expect_value(t, len(p1.entries), 2) do return
	testing.expect_value(t, p1.entries[0].name, "a.txt")
	testing.expect_value(t, p1.entries[1].name, "b.txt")
	testing.expect(t, p1.has_more, "p1 has_more")
	testing.expect(t, p1.next_cursor != "", "p1 next_cursor set")
	// The cursor is an opaque base64 offset; page 1 consumed 2 entries -> offset 2.
	decoded, _ := base64.decode(p1.next_cursor, allocator = context.temp_allocator)
	testing.expect_value(t, string(decoded), "2")

	// Page 2: same limit, using cursor -> c,d + has_more
	p2 := bridge_fs_list_dir("", true, p1.next_cursor, 2, root)
	if !testing.expect_value(t, len(p2.entries), 2) do return
	testing.expect_value(t, p2.entries[0].name, "c.txt")
	testing.expect_value(t, p2.entries[1].name, "d.txt")
	testing.expect(t, p2.has_more, "p2 has_more")

	// Page 3: last entry, no more
	p3 := bridge_fs_list_dir("", true, p2.next_cursor, 2, root)
	if !testing.expect_value(t, len(p3.entries), 1) do return
	testing.expect_value(t, p3.entries[0].name, "e.txt")
	testing.expect(t, !p3.has_more, "p3 no more")
	testing.expect_value(t, p3.next_cursor, "")
}

@(test)
fs_list_malformed_cursor_falls_back_to_first_page :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "badcursor")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "a.txt", "a")
	fs_test_seed_file(t, root, "b.txt", "b")
	res := bridge_fs_list_dir("", true, "not-valid-base64!!", 200, root)
	testing.expect(t, res.ok, "ok")
	if !testing.expect_value(t, len(res.entries), 2) do return
	testing.expect_value(t, res.entries[0].name, "a.txt")
}

// --- hidden filter -------------------------------------------------------

@(test)
fs_list_hidden_filter_omits_dotfiles :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "hidden")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "visible.txt", "v")
	fs_test_seed_file(t, root, ".secret", "s")
	fs_test_seed_dir(t, root, ".git")

	// include_hidden=false -> only visible.txt
	hidden_off := bridge_fs_list_dir("", false, "", 200, root)
	testing.expect(t, hidden_off.ok, "ok")
	if !testing.expect_value(t, len(hidden_off.entries), 1) do return
	testing.expect_value(t, hidden_off.entries[0].name, "visible.txt")
	testing.expect(t, !hidden_off.entries[0].hidden, "visible not hidden")

	// include_hidden=true -> all three, with hidden flag set on dotfiles
	hidden_on := bridge_fs_list_dir("", true, "", 200, root)
	testing.expect_value(t, len(hidden_on.entries), 3)
	saw_hidden := false
	for e in hidden_on.entries {
		if e.name == ".secret" || e.name == ".git" do testing.expect(t, e.hidden, "dotfile hidden flag")
		if e.hidden do saw_hidden = true
	}
	testing.expect(t, saw_hidden, "saw a hidden entry")
}

// --- containment: list/read/create/move/delete ---------------------------

@(test)
fs_list_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_list")
	defer fs_test_cleanup(root)
	res := bridge_fs_list_dir("../../../etc", true, "", 200, root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_read_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_read")
	defer fs_test_cleanup(root)
	res := bridge_fs_read_file("../../../etc/passwd", root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_read_reports_not_a_file_for_dir :: proc(t: ^testing.T) {
	bridge_fs_test_vault_hook = fs_test_unlocked_vault
	defer bridge_fs_test_vault_hook = nil
	root := fs_test_make_root(t, "read_dir")
	defer fs_test_cleanup(root)
	fs_test_seed_dir(t, root, "adir")
	res := bridge_fs_read_file("adir", root)
	testing.expect(t, !res.ok, "dir not a file")
	testing.expect_value(t, res.error_code, "not_a_file")
}

@(test)
fs_read_gates_unsupported_type :: proc(t: ^testing.T) {
	bridge_fs_test_vault_hook = fs_test_unlocked_vault
	defer bridge_fs_test_vault_hook = nil
	root := fs_test_make_root(t, "read_bin")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "blob.bin", "\x00\x01\x02")
	res := bridge_fs_read_file("blob.bin", root)
	testing.expect(t, res.ok, "request ok")
	testing.expect(t, !res.viewable, "not viewable")
	testing.expect_value(t, res.error_code, "unsupported_type")
}

FS_TEST_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// fs_test_unlocked_vault is the explicit vault state injected through
// bridge_fs_test_vault_hook: unlocked with FS_TEST_VAULT_KEY, never the ambient keyring.
fs_test_unlocked_vault :: proc() -> (Vault_Status, vault.Vault_Keyring) {
	return .Unlocked, test_keyring_from_hex(FS_TEST_VAULT_KEY)
}

// fs_test_expect_sealed: read content always leaves sealed; it opens to want.
fs_test_expect_sealed :: proc(t: ^testing.T, content, want: string) {
	testing.expect(t, strings.has_prefix(content, vault.VAULT_V2_PREFIX), "content is sealed")
	decrypted, dec_ok := test_decrypt_hex(content, FS_TEST_VAULT_KEY)
	testing.expect(t, dec_ok, "decryption ok")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, want)
}

@(test)
fs_read_returns_utf8_text :: proc(t: ^testing.T) {
	bridge_fs_test_vault_hook = fs_test_unlocked_vault
	defer bridge_fs_test_vault_hook = nil
	root := fs_test_make_root(t, "read_txt")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "hello.md", "# hi")
	res := bridge_fs_read_file("hello.md", root)
	defer delete(res.content)
	testing.expect(t, res.ok && res.viewable, "viewable")
	testing.expect_value(t, res.encoding, "utf8")
	fs_test_expect_sealed(t, res.content, "# hi")
}

@(test)
fs_read_honors_configured_chunk_size :: proc(t: ^testing.T) {
	bridge_fs_test_vault_hook = fs_test_unlocked_vault
	defer bridge_fs_test_vault_hook = nil
	root := fs_test_make_root(t, "read_chunk")
	defer fs_test_cleanup(root)
	// Seed a 30-byte file
	content := "012345678901234567890123456789"
	fs_test_seed_file(t, root, "numbers.txt", content)

	// Temporarily override chunk size to 10
	orig_chunk_size := bridge_fs_read_page_bytes
	bridge_fs_read_page_bytes = 10
	defer { bridge_fs_read_page_bytes = orig_chunk_size }

	res := bridge_fs_read_file("numbers.txt", root)
	defer delete(res.content)
	testing.expect(t, res.ok && res.viewable, "viewable")
	testing.expect_value(t, res.bytes_returned, i64(10))
	fs_test_expect_sealed(t, res.content, "0123456789")
	testing.expect(t, !res.eof, "not eof yet")
}

@(test)
fs_create_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_create")
	defer fs_test_cleanup(root)
	res := bridge_fs_create_file("../evil.txt", root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_create_then_path_exists :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "create_exists")
	defer fs_test_cleanup(root)
	r1 := bridge_fs_create_file("new.txt", root)
	testing.expect(t, r1.ok && r1.created, "created")
	r2 := bridge_fs_create_file("new.txt", root)
	testing.expect(t, !r2.ok, "second create fails")
	testing.expect_value(t, r2.error_code, "path_exists")
}

@(test)
fs_move_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_move")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "src.txt", "x")
	// destination escapes root
	res := bridge_fs_move("src.txt", "../escaped.txt", root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_move_dest_exists :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "move_dest")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "a.txt", "a")
	fs_test_seed_file(t, root, "b.txt", "b")
	res := bridge_fs_move("a.txt", "b.txt", root)
	testing.expect(t, !res.ok, "dest exists rejected")
	testing.expect_value(t, res.error_code, "dest_exists")
}

@(test)
fs_move_renames_file :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "move_ok")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "old.txt", "data")
	res := bridge_fs_move("old.txt", "new.txt", root)
	testing.expect(t, res.ok, "move ok")
	testing.expect(t, !os.exists(strings.concatenate({root, "/old.txt"})), "old gone")
	testing.expect(t, os.exists(strings.concatenate({root, "/new.txt"})), "new present")
}

@(test)
fs_delete_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_delete")
	defer fs_test_cleanup(root)
	res := bridge_fs_delete("../../etc/hosts", false, root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_delete_refuses_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "delete_root")
	defer fs_test_cleanup(root)
	res := bridge_fs_delete("", false, root)
	testing.expect(t, !res.ok, "root delete refused")
	testing.expect_value(t, res.error_code, "cannot_delete_root")
}

@(test)
fs_delete_non_empty_dir_requires_recursive :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "delete_nonempty")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "dir/child.txt", "c")
	// Without recursive -> dir_not_empty
	res := bridge_fs_delete("dir", false, root)
	testing.expect(t, !res.ok, "non-empty rejected")
	testing.expect_value(t, res.error_code, "dir_not_empty")
	// With recursive -> deleted
	res2 := bridge_fs_delete("dir", true, root)
	testing.expect(t, res2.ok && res2.deleted, "recursive delete ok")
	testing.expect(t, !os.exists(strings.concatenate({root, "/dir"})), "dir gone")
}

// --- project-root override semantics (hub project-scoped relay) ----------

@(test)
fs_project_root_override_scopes_listing :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "proj_root")
	defer fs_test_cleanup(root)
	// A project subtree with its own file, plus a sibling outside the project.
	fs_test_seed_file(t, root, "proj/inside.txt", "in")
	fs_test_seed_file(t, root, "outside.txt", "out")
	proj_root := strings.concatenate({root, "/proj"})
	defer delete(proj_root)

	res := bridge_fs_list_dir("", true, "", 200, proj_root)
	testing.expect(t, res.ok, "list ok")
	testing.expect_value(t, res.root, proj_root)
	if !testing.expect_value(t, len(res.entries), 1) do return
	testing.expect_value(t, res.entries[0].name, "inside.txt")
	// parent of the project root is "" (breadcrumb stops at project root).
	testing.expect_value(t, res.parent, "")
}

@(test)
fs_project_root_override_blocks_escape_above_project :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "proj_escape")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "proj/inside.txt", "in")
	fs_test_seed_file(t, root, "secret.txt", "s")
	proj_root := strings.concatenate({root, "/proj"})
	defer delete(proj_root)

	// "../secret.txt" is still within the GLOBAL bridge root but escapes the
	// project root -> must be rejected.
	res := bridge_fs_read_file("../secret.txt", proj_root)
	testing.expect(t, !res.ok, "escape above project rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_project_root_override_rejects_root_outside_bridge :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "proj_ext_root") // pins the global base
	defer fs_test_cleanup(root)

	// Valid external directories on the host (e.g. /etc or a directory outside bridge root)
	// are now accepted as valid project / task-chain roots.
	can_etc, ok_etc := bridge_fs_effective_root("/etc")
	testing.expect(t, ok_etc, "effective root for /etc ok")
	testing.expect_value(t, can_etc, "/etc")

	res_valid := bridge_fs_list_dir("", true, "", 200, "/etc")
	testing.expect(t, res_valid.ok, "valid external directory accepted")

	// Non-existent directory overrides must be rejected.
	_, ok_bad := bridge_fs_effective_root("/nonexistent_ham_fs_test_dir_12345")
	testing.expect(t, !ok_bad, "non-existent directory ok=false")

	res_nonexistent := bridge_fs_list_dir("", true, "", 200, "/nonexistent_ham_fs_test_dir_12345")
	testing.expect(t, !res_nonexistent.ok, "non-existent directory rejected")
	testing.expect_value(t, res_nonexistent.error_code, "path_outside_root")

	// Subpath containment inside the external root remains enforced: attempts to escape
	// with '..' above the root are still rejected with path_outside_root.
	res_escape := bridge_fs_read_file("../passwd", "/etc")
	testing.expect(t, !res_escape.ok, "escape above external root rejected")
	testing.expect_value(t, res_escape.error_code, "path_outside_root")
}

// --- agent instance run-dir (read-only) ----------------------------------
// The run-dir explorer sandboxes to an instance's bridge-managed run directory,
// which lives OUTSIDE the global bridge_fs_root. bridge_fs_run_dir_root resolves +
// contains it to the instances base, and list/read are called with
// root_prevalidated=true so the global-root check is skipped while the requested
// path is still re-sandboxed to the run dir.

@(test)
fs_run_dir_root_resolves_within_instances_base :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_dir := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved_dir }

	base := fs_test_make_root(t, "rundir_base")
	defer fs_test_cleanup(base)
	bridge_config.local_endpoint_run_dir = base
	// The instance dir need not exist yet (agent may not have launched).
	root, ok := bridge_fs_run_dir_root("inst_abc123")
	defer if ok do delete(root)
	testing.expect(t, ok, "run-dir root resolves")
	testing.expect(t, strings.has_suffix(root, "/instances/inst_abc123"), "root is <base>/instances/<id>")
}

@(test)
fs_run_dir_root_sanitizes_instance_id :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_dir := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved_dir }

	base := fs_test_make_root(t, "rundir_sanitize")
	defer fs_test_cleanup(base)
	bridge_config.local_endpoint_run_dir = base
	// Slashes are stripped by bridge_runtime_safe_part, so a traversal-looking id
	// collapses to a single contained component (cannot escape the instances base).
	dirty := "inst/../../etc"
	root, ok := bridge_fs_run_dir_root(dirty)
	defer if ok do delete(root)
	testing.expect(t, ok, "sanitized run-dir root resolves")
	expected_suffix := strings.concatenate({"/instances/", bridge_runtime_safe_part(dirty)})
	defer delete(expected_suffix)
	testing.expect(t, strings.has_suffix(root, expected_suffix), "id sanitized to one contained component")
	testing.expect(t, !strings.has_suffix(root, "/etc"), "no traversal to /etc")
}

@(test)
fs_run_dir_root_rejects_empty_instance_id :: proc(t: ^testing.T) {
	_, ok := bridge_fs_run_dir_root("")
	testing.expect(t, !ok, "empty instance id rejected")
}

@(test)
fs_run_dir_root_canonicalizes_symlinked_base :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_dir := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved_dir }

	// Regression: on hosts where the instances base traverses a symlink (e.g.
	// macOS /tmp -> /private/tmp), the raw (unresolved) base failed to prefix-match
	// the symlink-resolved run dir, so every run-dir op returned path_outside_root.
	// bridge_fs_run_dir_root must canonicalize the base before the containment check.
	real_base := fs_test_make_root(t, "rundir_symlink_real")
	defer fs_test_cleanup(real_base)
	// A sibling symlink pointing at the real base; configure the LINK path as the
	// run dir so resolution has to follow the symlink.
	link_base := strings.concatenate({real_base, "_link"})
	defer fs_test_cleanup(link_base)
	if os.symlink(real_base, link_base) != nil {
		testing.expect(t, false, "could not create symlink base (platform lacks symlink support)")
		return
	}
	bridge_config.local_endpoint_run_dir = link_base

	root, ok := bridge_fs_run_dir_root("inst_symlink1")
	defer if ok do delete(root)
	testing.expect(t, ok, "run-dir root resolves through a symlinked base")
	testing.expect(t, strings.has_suffix(root, "/instances/inst_symlink1"), "root ends at <id>")

	// End-to-end: a listing through the resolved run dir succeeds (no path_outside_root).
	fs_test_seed_file(t, root, "AGENTS.md", "hi")
	res := bridge_fs_list_dir("", true, "", 200, root, true)
	testing.expect(t, res.ok, "list through symlinked run dir ok (no path_outside_root)")
	testing.expect_value(t, len(res.entries), 1)
}

@(test)
fs_run_dir_prevalidated_list_and_blocks_escape :: proc(t: ^testing.T) {
	run_dir := fs_test_make_root(t, "rundir_list")
	defer fs_test_cleanup(run_dir)
	fs_test_seed_file(t, run_dir, "AGENTS.md", "hello")
	fs_test_seed_file(t, run_dir, "bin/ham-ctl", "wrapper")

	// Prevalidated root lists the run dir even though it is passed directly (the
	// call path that a run dir OUTSIDE bridge_fs_root would take). Hidden shown.
	res := bridge_fs_list_dir("", true, "", 200, run_dir, true)
	testing.expect(t, res.ok, "prevalidated list ok")
	testing.expect_value(t, len(res.entries), 2)

	// Traversal above the run dir is still rejected.
	escape := bridge_fs_list_dir("../..", true, "", 200, run_dir, true)
	testing.expect(t, !escape.ok, "escape above run dir rejected")
	testing.expect_value(t, escape.error_code, "path_outside_root")
}

@(test)
fs_run_dir_prevalidated_read_and_blocks_escape :: proc(t: ^testing.T) {
	bridge_fs_test_vault_hook = fs_test_unlocked_vault
	defer bridge_fs_test_vault_hook = nil
	run_dir := fs_test_make_root(t, "rundir_read")
	defer fs_test_cleanup(run_dir)
	fs_test_seed_file(t, run_dir, "CLAUDE.md", "# context")
	// A sibling outside the run dir (under the shared temp base) to attempt escape.
	fs_test_seed_file(t, run_dir, "../rundir_read_secret.txt", "secret")
	defer fs_test_cleanup(strings.concatenate({run_dir, "/../rundir_read_secret.txt"}))

	ok_read := bridge_fs_read_file("CLAUDE.md", run_dir, 0, 0, true)
	defer delete(ok_read.content)
	testing.expect(t, ok_read.ok, "prevalidated read ok")
	testing.expect(t, ok_read.viewable, "file viewable")
	fs_test_expect_sealed(t, ok_read.content, "# context")

	escape := bridge_fs_read_file("../rundir_read_secret.txt", run_dir, 0, 0, true)
	testing.expect(t, !escape.ok, "read escape above run dir rejected")
	testing.expect_value(t, escape.error_code, "path_outside_root")
}

// --- Wire Typed Structs & Serialization Tests (REQ-P2-FS-MGMT) -----------

@(test)
fs_wire_commands_unmarshal_whitespace_and_reversed_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// 1. Bridge_Fs_List_Command
	raw_list := `
	{
		"root": "/tmp/root",
		"limit": 50,
		"cursor": "cur_abc",
		"include_hidden": false,
		"path": "sub/dir",
		"command_id": "cmd_list_1",
		"instance_id": "inst_1",
		"type": "fs_list_dir"
	}`
	cmd_list: Bridge_Fs_List_Command
	err := json.unmarshal_string(raw_list, &cmd_list, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal list command ok")
	testing.expect_value(t, cmd_list.command_id, "cmd_list_1")
	testing.expect_value(t, cmd_list.path, "sub/dir")
	testing.expect_value(t, cmd_list.include_hidden.?, false)
	testing.expect_value(t, cmd_list.cursor, "cur_abc")
	testing.expect_value(t, cmd_list.limit, 50)
	testing.expect_value(t, cmd_list.root, "/tmp/root")
	testing.expect_value(t, cmd_list.instance_id, "inst_1")

	// 2. Bridge_Fs_Read_Command
	raw_read := `
	{
		"limit": 4096,
		"offset": 1024,
		"root": "/tmp/root",
		"instance_id": "inst_2",
		"path": "test.txt",
		"command_id": "cmd_read_1",
		"type": "fs_read_file"
	}`
	cmd_read: Bridge_Fs_Read_Command
	err = json.unmarshal_string(raw_read, &cmd_read, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal read command ok")
	testing.expect_value(t, cmd_read.command_id, "cmd_read_1")
	testing.expect_value(t, cmd_read.path, "test.txt")
	testing.expect_value(t, cmd_read.offset, 1024)
	testing.expect_value(t, cmd_read.limit, 4096)
	testing.expect_value(t, cmd_read.instance_id, "inst_2")

	// 3. Bridge_Fs_Create_File_Command
	raw_create := `
	{
		"root": "/tmp/root",
		"path": "new_file.txt",
		"command_id": "cmd_create_1",
		"type": "fs_create_file"
	}`
	cmd_create: Bridge_Fs_Create_File_Command
	err = json.unmarshal_string(raw_create, &cmd_create, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal create command ok")
	testing.expect_value(t, cmd_create.command_id, "cmd_create_1")
	testing.expect_value(t, cmd_create.path, "new_file.txt")

	// 4. Bridge_Fs_Write_File_Command
	raw_write := `
	{
		"root": "/tmp/root",
		"content": "hello world",
		"path": "write.txt",
		"command_id": "cmd_write_1",
		"type": "fs_write_file"
	}`
	cmd_write: Bridge_Fs_Write_File_Command
	err = json.unmarshal_string(raw_write, &cmd_write, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal write command ok")
	testing.expect_value(t, cmd_write.command_id, "cmd_write_1")
	testing.expect_value(t, cmd_write.path, "write.txt")
	testing.expect_value(t, cmd_write.content, "hello world")

	// 5. Bridge_Fs_Batch_Write_Command
	raw_batch := `
	{
		"files": [
			{"content": "c1", "path": "f1.txt"},
			{"content": "c2", "path": "f2.txt"}
		],
		"root": "/tmp/root",
		"command_id": "cmd_batch_1",
		"type": "fs_batch_write"
	}`
	cmd_batch: Bridge_Fs_Batch_Write_Command
	err = json.unmarshal_string(raw_batch, &cmd_batch, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal batch write command ok")
	testing.expect_value(t, cmd_batch.command_id, "cmd_batch_1")
	if !testing.expect_value(t, len(cmd_batch.files), 2) do return
	testing.expect_value(t, cmd_batch.files[0].path, "f1.txt")
	testing.expect_value(t, cmd_batch.files[0].content, "c1")
	testing.expect_value(t, cmd_batch.files[1].path, "f2.txt")
	testing.expect_value(t, cmd_batch.files[1].content, "c2")

	// 6. Bridge_Fs_Move_Command
	raw_move := `
	{
		"root": "/tmp/root",
		"to": "dst.txt",
		"from": "src.txt",
		"command_id": "cmd_move_1",
		"type": "fs_move"
	}`
	cmd_move: Bridge_Fs_Move_Command
	err = json.unmarshal_string(raw_move, &cmd_move, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal move command ok")
	testing.expect_value(t, cmd_move.command_id, "cmd_move_1")
	testing.expect_value(t, cmd_move.from, "src.txt")
	testing.expect_value(t, cmd_move.to, "dst.txt")

	// 7. Bridge_Fs_Delete_Command
	raw_del := `
	{
		"root": "/tmp/root",
		"recursive": true,
		"path": "del_dir",
		"command_id": "cmd_del_1",
		"type": "fs_delete"
	}`
	cmd_del: Bridge_Fs_Delete_Command
	err = json.unmarshal_string(raw_del, &cmd_del, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal delete command ok")
	testing.expect_value(t, cmd_del.command_id, "cmd_del_1")
	testing.expect_value(t, cmd_del.path, "del_dir")
	testing.expect_value(t, cmd_del.recursive, true)

	// 8. Bridge_Fs_Stat_Command
	raw_stat := `
	{
		"root": "/tmp/root",
		"path": "check.txt",
		"command_id": "cmd_stat_1",
		"type": "fs_stat"
	}`
	cmd_stat: Bridge_Fs_Stat_Command
	err = json.unmarshal_string(raw_stat, &cmd_stat, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal stat command ok")
	testing.expect_value(t, cmd_stat.command_id, "cmd_stat_1")
	testing.expect_value(t, cmd_stat.path, "check.txt")

	// 9. Bridge_Fs_Mkdir_Command
	raw_mkdir := `
	{
		"root": "/tmp/root",
		"path": "new_dir",
		"command_id": "cmd_mkdir_1",
		"type": "fs_make_dir"
	}`
	cmd_mkdir: Bridge_Fs_Mkdir_Command
	err = json.unmarshal_string(raw_mkdir, &cmd_mkdir, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal mkdir command ok")
	testing.expect_value(t, cmd_mkdir.command_id, "cmd_mkdir_1")
	testing.expect_value(t, cmd_mkdir.path, "new_dir")

	// 10. Bridge_Fs_Find_Files_Command
	raw_find := `
	{
		"root": "/tmp/root",
		"limit": 25,
		"query": "*.odin",
		"command_id": "cmd_find_1",
		"type": "fs_find_files"
	}`
	cmd_find: Bridge_Fs_Find_Files_Command
	err = json.unmarshal_string(raw_find, &cmd_find, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal find command ok")
	testing.expect_value(t, cmd_find.command_id, "cmd_find_1")
	testing.expect_value(t, cmd_find.query, "*.odin")
	testing.expect_value(t, cmd_find.limit, 25)

	// 11. Bridge_Fs_Grep_Command
	raw_grep := `
	{
		"root": "/tmp/root",
		"max_results": 75,
		"limit": 10,
		"case_sensitive": true,
		"query": "needle",
		"command_id": "cmd_grep_1",
		"type": "fs_grep"
	}`
	cmd_grep: Bridge_Fs_Grep_Command
	err = json.unmarshal_string(raw_grep, &cmd_grep, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal grep command ok")
	testing.expect_value(t, cmd_grep.command_id, "cmd_grep_1")
	testing.expect_value(t, cmd_grep.query, "needle")
	testing.expect_value(t, cmd_grep.case_sensitive, true)
	testing.expect_value(t, cmd_grep.limit, 10)
	testing.expect_value(t, cmd_grep.max_results, 75)

	// Heap allocations must be 0 because temp_allocator was used
	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
fs_wire_results_round_trip_all_11_operations :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// 1. list_dir
	entries := [2]Bridge_Fs_Entry{
		{name = "alpha.txt", is_dir = false, hidden = false, has_git = false, size = 120, modified_at = "2026-10-01T00:00:00Z"},
		{name = "beta_dir", is_dir = true, hidden = false, has_git = true, size = 0, modified_at = "2026-10-02T00:00:00Z"},
	}
	r_list := Bridge_Fs_List_Result{
		ok = true,
		path = "/tmp/root",
		root = "/tmp/root",
		parent = "",
		entries = entries[:],
		next_cursor = "cursor_token",
		has_more = true,
		truncated = false,
	}
	json_list := bridge_fs_list_result_json("cmd_list", r_list)
	var_list: Bridge_Fs_List_Result_Wire
	err := json.unmarshal_string(json_list, &var_list, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_list)
	testing.expect(t, err == nil, "unmarshal list wire ok")
	testing.expect_value(t, var_list.type, "fs_list_dir_result")
	testing.expect_value(t, var_list.command_id, "cmd_list")
	testing.expect_value(t, var_list.ok, true)
	testing.expect_value(t, var_list.path, "/tmp/root")
	testing.expect_value(t, var_list.has_more, true)
	testing.expect_value(t, var_list.next_cursor.?, "cursor_token")
	if !testing.expect_value(t, len(var_list.entries), 2) do return
	testing.expect_value(t, var_list.entries[0].name, "alpha.txt")
	testing.expect_value(t, var_list.entries[1].has_git, true)

	// 2. read_file (viewable = true)
	r_read := Bridge_Fs_Read_File_Result{
		ok = true,
		path = "hello.txt",
		viewable = true,
		content = "line1\nline2",
		encoding = "utf8",
		mime = "text/plain",
		size = 11,
		offset = 0,
		bytes_returned = 11,
		eof = true,
		modified_at = "2026-10-03T10:00:00Z",
		truncated = false,
	}
	json_read := bridge_fs_read_file_result_json("cmd_read", r_read)
	var_read: Bridge_Fs_Read_Result_Wire
	err = json.unmarshal_string(json_read, &var_read, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_read)
	testing.expect(t, err == nil, "unmarshal read wire ok")
	testing.expect_value(t, var_read.type, "fs_read_file_result")
	testing.expect_value(t, var_read.command_id, "cmd_read")
	testing.expect_value(t, var_read.ok, true)
	testing.expect_value(t, var_read.viewable, true)
	testing.expect_value(t, var_read.content.?, "line1\nline2")
	testing.expect_value(t, var_read.encoding.?, "utf8")
	testing.expect_value(t, var_read.mime, "text/plain")
	testing.expect_value(t, var_read.eof, true)

	// 3. create_file
	r_create := Bridge_Fs_Create_File_Result{
		ok = true,
		path = "new.txt",
		created = true,
		within_root = true,
	}
	json_create := bridge_fs_create_file_result_json("cmd_create", r_create)
	var_create: Bridge_Fs_Create_File_Result_Wire
	err = json.unmarshal_string(json_create, &var_create, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_create)
	testing.expect(t, err == nil, "unmarshal create wire ok")
	testing.expect_value(t, var_create.type, "fs_create_file_result")
	testing.expect_value(t, var_create.command_id, "cmd_create")
	testing.expect_value(t, var_create.created, true)
	testing.expect_value(t, var_create.within_root, true)

	// 4. write_file
	r_write := Bridge_Fs_Write_File_Result{
		ok = true,
		path = "out.txt",
		bytes_written = 42,
		modified_at = "2026-10-03T11:00:00Z",
		within_root = true,
	}
	json_write := bridge_fs_write_file_result_json("cmd_write", r_write)
	var_write: Bridge_Fs_Write_Result_Wire
	err = json.unmarshal_string(json_write, &var_write, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_write)
	testing.expect(t, err == nil, "unmarshal write wire ok")
	testing.expect_value(t, var_write.type, "fs_write_file_result")
	testing.expect_value(t, var_write.command_id, "cmd_write")
	testing.expect_value(t, var_write.bytes_written, 42)
	testing.expect_value(t, var_write.within_root, true)

	// 5. batch_write
	saved := [1]Bridge_Fs_Saved_Item{
		{path = "s1.txt", bytes_written = 10, modified_at = "2026-10-03T12:00:00Z"},
	}
	errors := [1]Bridge_Fs_Error_Item{
		{path = "e1.txt", error_code = "permission_denied", message = "Access denied"},
	}
	r_batch := Bridge_Fs_Batch_Write_Result{
		ok = false,
		saved = saved[:],
		errors = errors[:],
		error_code = "batch_write_partial",
		message = "1 file failed",
	}
	json_batch := bridge_fs_batch_write_result_json("cmd_batch", r_batch)
	var_batch: Bridge_Fs_Batch_Write_Result_Wire
	err = json.unmarshal_string(json_batch, &var_batch, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_batch)
	testing.expect(t, err == nil, "unmarshal batch wire ok")
	testing.expect_value(t, var_batch.type, "fs_batch_write_result")
	testing.expect_value(t, var_batch.command_id, "cmd_batch")
	if !testing.expect_value(t, len(var_batch.saved), 1) do return
	testing.expect_value(t, var_batch.saved[0].path, "s1.txt")
	if !testing.expect_value(t, len(var_batch.errors), 1) do return
	testing.expect_value(t, var_batch.errors[0].error_code, "permission_denied")
	testing.expect_value(t, var_batch.error.cause, "batch_write_partial")

	// 6. move
	r_move := Bridge_Fs_Move_Result{
		ok = true,
		from = "from.txt",
		to = "to.txt",
		within_root = true,
	}
	json_move := bridge_fs_move_result_json("cmd_move", r_move)
	var_move: Bridge_Fs_Move_Result_Wire
	err = json.unmarshal_string(json_move, &var_move, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_move)
	testing.expect(t, err == nil, "unmarshal move wire ok")
	testing.expect_value(t, var_move.type, "fs_move_result")
	testing.expect_value(t, var_move.command_id, "cmd_move")
	testing.expect_value(t, var_move.from, "from.txt")
	testing.expect_value(t, var_move.to, "to.txt")

	// 7. delete
	r_delete := Bridge_Fs_Delete_Result{
		ok = true,
		path = "deleted.txt",
		deleted = true,
		within_root = true,
	}
	json_delete := bridge_fs_delete_result_json("cmd_del", r_delete)
	var_delete: Bridge_Fs_Delete_Result_Wire
	err = json.unmarshal_string(json_delete, &var_delete, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_delete)
	testing.expect(t, err == nil, "unmarshal delete wire ok")
	testing.expect_value(t, var_delete.type, "fs_delete_result")
	testing.expect_value(t, var_delete.command_id, "cmd_del")
	testing.expect_value(t, var_delete.deleted, true)

	// 8. stat
	r_stat := Bridge_Fs_Stat_Result{
		ok = true,
		path = "dir1",
		exists = true,
		is_dir = true,
		has_git = false,
		within_root = true,
	}
	json_stat := bridge_fs_stat_result_json("cmd_stat", r_stat)
	var_stat: Bridge_Fs_Stat_Result_Wire
	err = json.unmarshal_string(json_stat, &var_stat, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_stat)
	testing.expect(t, err == nil, "unmarshal stat wire ok")
	testing.expect_value(t, var_stat.type, "fs_stat_result")
	testing.expect_value(t, var_stat.command_id, "cmd_stat")
	testing.expect_value(t, var_stat.exists, true)
	testing.expect_value(t, var_stat.is_dir, true)

	// 9. mkdir
	r_mkdir := Bridge_Fs_Mkdir_Result{
		ok = true,
		path = "new_sub",
		created = true,
		within_root = true,
	}
	json_mkdir := bridge_fs_mkdir_result_json("cmd_mkdir", r_mkdir)
	var_mkdir: Bridge_Fs_Mkdir_Result_Wire
	err = json.unmarshal_string(json_mkdir, &var_mkdir, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_mkdir)
	testing.expect(t, err == nil, "unmarshal mkdir wire ok")
	testing.expect_value(t, var_mkdir.type, "fs_make_dir_result")
	testing.expect_value(t, var_mkdir.command_id, "cmd_mkdir")
	testing.expect_value(t, var_mkdir.created, true)

	// 10. find_files
	files_found := [2]string{"a.odin", "b.odin"}
	r_find := Bridge_Fs_Find_Files_Result{
		ok = true,
		root = "/tmp/root",
		files = files_found[:],
		truncated = false,
	}
	json_find := bridge_fs_find_files_result_json("cmd_find", r_find)
	var_find: Bridge_Fs_Find_Files_Result_Wire
	err = json.unmarshal_string(json_find, &var_find, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_find)
	testing.expect(t, err == nil, "unmarshal find wire ok")
	testing.expect_value(t, var_find.type, "fs_find_files_result")
	testing.expect_value(t, var_find.command_id, "cmd_find")
	if !testing.expect_value(t, len(var_find.files), 2) do return
	testing.expect_value(t, var_find.files[0], "a.odin")

	// 11. grep
	matches := [1]Bridge_Fs_Grep_Match{
		{path = "m.odin", line_number = 42, line = "target match"},
	}
	r_grep := Bridge_Fs_Grep_Result{
		ok = true,
		root = "/tmp/root",
		matches = matches[:],
		truncated = false,
	}
	json_grep := bridge_fs_grep_result_json("cmd_grep", r_grep)
	var_grep: Bridge_Fs_Grep_Result_Wire
	err = json.unmarshal_string(json_grep, &var_grep, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_grep)
	testing.expect(t, err == nil, "unmarshal grep wire ok")
	testing.expect_value(t, var_grep.type, "fs_grep_result")
	testing.expect_value(t, var_grep.command_id, "cmd_grep")
	if !testing.expect_value(t, len(var_grep.matches), 1) do return
	testing.expect_value(t, var_grep.matches[0].line_number, 42)
	testing.expect_value(t, var_grep.matches[0].line, "target match")

	// All allocations freed cleanly
	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
fs_wire_read_file_result_viewable_omits_content_and_encoding :: proc(t: ^testing.T) {
	// When viewable = false, content and encoding must not appear in JSON.
	r_binary := Bridge_Fs_Read_File_Result{
		ok = true,
		path = "bin.exe",
		viewable = false,
		content = "",
		encoding = "",
		mime = "application/octet-stream",
		size = 2048,
		bytes_returned = 0,
		eof = true,
	}
	json_bin := bridge_fs_read_file_result_json("cmd_bin", r_binary)
	defer delete(json_bin)

	testing.expect(t, !strings.contains(json_bin, "\"content\""), "content must be omitted when viewable = false")
	testing.expect(t, !strings.contains(json_bin, "\"encoding\""), "encoding must be omitted when viewable = false")

	// When viewable = true and content is empty, content and encoding must be present
	r_empty := Bridge_Fs_Read_File_Result{
		ok = true,
		path = "empty.txt",
		viewable = true,
		content = "",
		encoding = "utf8",
		mime = "text/plain",
		size = 0,
		bytes_returned = 0,
		eof = true,
	}
	json_empty := bridge_fs_read_file_result_json("cmd_empty", r_empty)
	defer delete(json_empty)

	testing.expect(t, strings.contains(json_empty, "\"content\":\"\""), "content must be present when viewable = true")
	testing.expect(t, strings.contains(json_empty, "\"encoding\":\"utf8\""), "encoding must be present when viewable = true")
}

@(test)
fs_wire_list_result_null_vs_string_cursor :: proc(t: ^testing.T) {
	// Empty cursor outputs "next_cursor":null
	r_no_cursor := Bridge_Fs_List_Result{
		ok = true,
		path = "/tmp",
		root = "/tmp",
		next_cursor = "",
	}
	json_no_cursor := bridge_fs_list_result_json("cmd_nc", r_no_cursor)
	defer delete(json_no_cursor)
	testing.expect(t, strings.contains(json_no_cursor, "\"next_cursor\":null"), "empty cursor must serialize as null")

	// Non-empty cursor outputs "next_cursor":"token"
	r_with_cursor := Bridge_Fs_List_Result{
		ok = true,
		path = "/tmp",
		root = "/tmp",
		next_cursor = "offset_100",
	}
	json_with_cursor := bridge_fs_list_result_json("cmd_wc", r_with_cursor)
	defer delete(json_with_cursor)
	testing.expect(t, strings.contains(json_with_cursor, "\"next_cursor\":\"offset_100\""), "non-empty cursor must serialize as string")
}

@(test)
fs_wire_special_characters_escaping :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// Filenames and paths with quotes, backslashes, tabs, and unicode
	entries := [1]Bridge_Fs_Entry{
		{
			name = "file \"quoted\" \\ backslash \t tab \u2764.txt",
			is_dir = false,
			size = 50,
			modified_at = "2026-10-03T12:00:00Z",
		},
	}
	r_list := Bridge_Fs_List_Result{
		ok = true,
		path = "/path/with \"quotes\"/and \\backslashes\\",
		root = "/path/with \"quotes\"/and \\backslashes\\",
		entries = entries[:],
	}
	json_out := bridge_fs_list_result_json("cmd_escapes", r_list)
	var_list: Bridge_Fs_List_Result_Wire
	err := json.unmarshal_string(json_out, &var_list, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_out)
	testing.expect(t, err == nil, "unmarshaling special characters must succeed")
	testing.expect_value(t, var_list.path, "/path/with \"quotes\"/and \\backslashes\\")
	if !testing.expect_value(t, len(var_list.entries), 1) do return
	testing.expect_value(t, var_list.entries[0].name, "file \"quoted\" \\ backslash \t tab \u2764.txt")

	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
fs_wire_error_responses_round_trip :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// Error on read_file
	r_err := Bridge_Fs_Read_File_Result{
		ok = false,
		path = "/secret",
		viewable = false,
		error_code = "path_outside_root",
		message = "Path is outside sandbox root",
	}
	json_err := bridge_fs_read_file_result_json("cmd_err_1", r_err)
	var_err: Bridge_Fs_Read_Result_Wire
	err := json.unmarshal_string(json_err, &var_err, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	delete(json_err)
	testing.expect(t, err == nil, "unmarshal error wire ok")
	testing.expect_value(t, var_err.ok, false)
	testing.expect_value(t, var_err.error.cause, "path_outside_root")
	testing.expect_value(t, var_err.error.message, "Path is outside sandbox root")

	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

// --- Zero-Trust Vault Encryption in Bridge FS Tests (REQ-FS-ENC-1, REQ-FS-ENC-2, REQ-FS-ENC-3) ---

@(test)
fs_vault_read_file_encryption_lifecycle :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
	}

	root := fs_test_make_root(t, "vault_read")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "confidential.txt", "classified data 12345")

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	// 1. With active vault key: read_file encrypts content as a v2 vault token
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(test_key))
	res_enc := bridge_fs_read_file("confidential.txt", root)
	defer delete(res_enc.content)
	testing.expect(t, res_enc.ok && res_enc.viewable, "read encrypted ok")
	testing.expect(t, strings.has_prefix(res_enc.content, vault.VAULT_V2_PREFIX), "content must be a v2 vault token")
	decrypted, dec_ok := test_decrypt_hex(res_enc.content, test_key)
	testing.expect(t, dec_ok, "decryption of read content ok")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, "classified data 12345")

	// 2. Without a keyring the read is refused (there is no plaintext mode).
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", "unconfigured_key")
	res_locked := bridge_fs_read_file("confidential.txt", root)
	defer delete(res_locked.content)
	testing.expect(t, !res_locked.ok && res_locked.error_code == "vault_locked", "read without a keyring is vault_locked")
	testing.expect(t, !strings.contains(res_locked.content, "classified"), "no plaintext")
}

// test_fs_write_seal seals plaintext the way the UI does for a file write: bound to
// this bridge (bridge_config.daemon_id), the sandbox root the bridge resolves for
// `root` (what fs results report as `root`) and the exact request path (finding N4).
test_fs_write_seal :: proc(plaintext, key_hex, root, path: string, epoch: u32 = 1) -> string {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	_ = vault.hex_decode_into(key[:], key_hex)
	nonce: [vault.NONCE_BYTES]byte
	crypto.rand_bytes(nonce[:])
	canonical_root, _ := bridge_fs_effective_root(root)
	tok, _ := vault.fs_write_seal_with_nonce(transmute([]byte)plaintext, key[:], test_vault_id(), epoch, bridge_config.daemon_id, canonical_root, path, nonce[:], context.temp_allocator)
	return tok
}

@(test)
fs_vault_write_file_requires_path_bound_ciphertext :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	// Writes are sealed for THIS bridge id (the AAD binds it).
	test_bridge_a, _ := keystore_test_bridge_ids()
	prev_daemon := keystore_test_set_daemon_id(test_bridge_a)
	defer bridge_config.daemon_id = prev_daemon

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
	}

	root := fs_test_make_root(t, "vault_write")
	defer fs_test_cleanup(root)

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	wrong_key := "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(test_key))

	expect_rejected :: proc(t: ^testing.T, root, path, content, why: string) {
		res := bridge_fs_write_file(path, content, root)
		testing.expectf(t, !res.ok && res.error_code == "invalid_vault_key", "%s must be rejected, got %v %s", why, res.ok, res.error_code)
		disk, _ := filepath.join([]string{root, path}, context.temp_allocator)
		testing.expectf(t, !os.exists(disk), "%s must not touch disk", why)
	}

	// 1. Content sealed for this bridge and this path is written in plaintext to disk.
	plaintext := "Decrypted disk content 999"
	res_write := bridge_fs_write_file("valid.txt", test_fs_write_seal(plaintext, test_key, root, "valid.txt"), root)
	testing.expect(t, res_write.ok, "write with a path-bound payload ok")
	testing.expect_value(t, res_write.bytes_written, len(plaintext))
	disk_content, rerr := os.read_entire_file_from_path(res_write.path, context.allocator)
	testing.expect(t, rerr == nil, "read written file from disk ok")
	defer delete(disk_content, context.allocator)
	testing.expect_value(t, string(disk_content), plaintext)

	// 2. Everything else is refused before the disk is touched.
	expect_rejected(t, root, "plain.txt", "plaintext content", "plaintext")
	expect_rejected(t, root, "wrong.txt", test_fs_write_seal("x", wrong_key, root, "wrong.txt"), "a wrong key")
	expect_rejected(t, root, "other.txt", test_fs_write_seal("x", test_key, root, "valid.txt"), "a token sealed for another path")
	// P4 root binding: a write sealed for the same relative path under ANOTHER project
	// root (a hub replaying project A's write into project B) is refused.
	other_root := fs_test_make_root(t, "vault_write_other")
	defer fs_test_cleanup(other_root)
	expect_rejected(t, root, "env.txt", test_fs_write_seal("x", test_key, other_root, "env.txt"), "a token sealed for another project root")
	content_env, _ := test_encrypt_hex("x", test_key)
	defer delete(content_env)
	expect_rejected(t, root, "content.txt", content_env, "a content envelope")
	good := test_fs_write_seal("x", test_key, root, "tampered.txt")
	tampered := strings.concatenate({good[:len(good) - 4], "AAA="}, context.temp_allocator)
	expect_rejected(t, root, "tampered.txt", tampered, "tampered ciphertext")

	// 3. Without a keyring the write is vault_locked.
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", "unconfigured_key")
	res_locked := bridge_fs_write_file("locked.txt", test_fs_write_seal("x", test_key, root, "locked.txt"), root)
	testing.expect(t, !res_locked.ok && res_locked.error_code == "vault_locked", res_locked.error_code)
}

@(test)
fs_vault_batch_write_enforces_decryption_per_item :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	// Writes are sealed for THIS bridge id (the AAD binds it).
	test_bridge_a, _ := keystore_test_bridge_ids()
	prev_daemon := keystore_test_set_daemon_id(test_bridge_a)
	defer bridge_config.daemon_id = prev_daemon

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
	}

	root := fs_test_make_root(t, "vault_batch")
	defer fs_test_cleanup(root)

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	wrong_key := "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(test_key))

	items := make([dynamic]Bridge_Fs_Write_Item)
	defer delete(items)
	append(&items, Bridge_Fs_Write_Item{path = "good.txt", content = test_fs_write_seal("Good file content", test_key, root, "good.txt")})
	append(&items, Bridge_Fs_Write_Item{path = "bad.txt", content = test_fs_write_seal("Bad file content", wrong_key, root, "bad.txt")})

	batch_res := bridge_fs_batch_write(items, root)
	defer bridge_fs_batch_write_result_delete(&batch_res)

	testing.expect(t, !batch_res.ok, "batch write with one bad file should not be ok")
	testing.expect_value(t, batch_res.error_code, "batch_write_partial")
	testing.expect_value(t, len(batch_res.saved), 1)
	if !testing.expect_value(t, len(batch_res.errors), 1) do return
	testing.expect_value(t, batch_res.errors[0].error_code, "invalid_vault_key")

	good_path, _ := filepath.join([]string{root, "good.txt"}, context.allocator)
	defer delete(good_path, context.allocator)
	testing.expect(t, os.exists(good_path), "good file must exist on disk")

	bad_path, _ := filepath.join([]string{root, "bad.txt"}, context.allocator)
	defer delete(bad_path, context.allocator)
	testing.expect(t, !os.exists(bad_path), "bad file must NOT exist on disk")
}

@(test)
bridge_fs_traversals_fail_before_work_when_command_deadline_expired :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "expired_traversal")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "keep.txt", "still here")
	past := time.to_unix_nanoseconds(time.now()) - i64(time.Millisecond)

	listed := bridge_fs_list_dir("", true, "", 100, root, false, past)
	defer bridge_fs_list_result_delete(&listed)
	testing.expect(t, !listed.ok)
	testing.expect_value(t, listed.error_code, "deadline_exceeded")

	found := bridge_fs_find_files("keep", 100, root, past)
	defer bridge_fs_find_files_result_delete(&found)
	testing.expect(t, !found.ok)
	testing.expect_value(t, found.error_code, "deadline_exceeded")

	deleted := bridge_fs_delete("keep.txt", false, root, past)
	testing.expect(t, !deleted.ok)
	testing.expect_value(t, deleted.error_code, "deadline_exceeded")
	path, _ := filepath.join([]string{root, "keep.txt"}, context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, os.exists(path), "expired mutation must not begin")
}

// Creates only the missing tail; existing ancestors are never mkdir()ed.
@(test)
test_bridge_make_directory_all_creates_missing_tail_only :: proc(t: ^testing.T) {
	base := fmt.tprintf("%s/ham-mkdir-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	testing.expect_value(t, os.make_directory(base), nil)
	defer os.remove_all(base)
	deep := strings.concatenate({base, "/a/b/c/"}, context.temp_allocator)
	testing.expect_value(t, bridge_make_directory_all(deep), nil)
	testing.expect(t, os.exists(strings.concatenate({base, "/a/b/c"}, context.temp_allocator)), "created")
	testing.expect_value(t, bridge_make_directory_all(deep), nil) // idempotent
	testing.expect_value(t, bridge_make_directory_all(base), nil)  // exists already
	testing.expect_value(t, bridge_make_directory_all(strings.concatenate({base, "/x"}, context.temp_allocator)), nil)
	testing.expect(t, os.exists(strings.concatenate({base, "/x"}, context.temp_allocator)), "single missing component")
}

// Windows: cleaned paths are `\`-separated and case-insensitive, so containment must
// not assume root + "/" (regression: every subdirectory was path_outside_root).
@(test)
test_bridge_fs_is_within_root_windows_separators :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		root := `C:\Users\ashis`
		testing.expect(t, bridge_fs_is_within_root(`C:\Users\ashis`, root), "root itself")
		testing.expect(t, bridge_fs_is_within_root(`C:\Users\ashis\Cisco Packet Tracer 8.2.2`, root), "backslash child")
		testing.expect(t, bridge_fs_is_within_root(`C:\Users\ashis/desktop/brolabs`, root), "mixed separators")
		testing.expect(t, bridge_fs_is_within_root(`c:\users\ASHIS\Desktop`, root), "case-insensitive")
		testing.expect(t, !bridge_fs_is_within_root(`C:\Users\ashisX`, root), "sibling prefix rejected")
		testing.expect(t, !bridge_fs_is_within_root(`C:\Users`, root), "parent rejected")
		testing.expect(t, !bridge_fs_is_within_root(`D:\Users\ashis\x`, root), "other drive rejected")
		testing.expect(t, bridge_fs_is_within_root(`C:\Windows`, `C:\`), "drive root contains children")
	}
}
