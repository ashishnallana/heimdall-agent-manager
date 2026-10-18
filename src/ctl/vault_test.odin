package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import cfg_lib "odin_test:lib/config"

// Serialises every test that touches AMBIENT vault state — the HEIMDALL_HOME /
// HEIMDALL_VAULT_KEY environment and the vault key file they resolve to. Those
// are process-wide, so such tests cannot run concurrently under the multi-thread
// test runner. Hold this for the whole body, and open the sandbox below inside it.
vault_test_mutex: sync.Mutex

// ── Vault test sandbox (REQ-VAULT-4) ─────────────────────────────────────────
//
// `odin test src/ctl` used to run against the OPERATOR'S REAL vault key file,
// ~/.config/heimdall/vault_key, so a test that wrote or cleared it destroyed
// production state. (The commands that did so and the file source are gone since
// REQ-T6; the sandbox stays because it also neutralises the env and bridge sources,
// and lets a test plant a legacy file to prove it is ignored.) It did — an
// unsandboxed run on 2026-09-28 at 14:25:06 unlinked the operator's key and
// degraded vault encryption host-wide until it was restored.
//
// `expand_home` honours HEIMDALL_HOME ahead of HOME (src/lib/config/config.odin:251-254),
// so redirecting that ONE variable relocates the entire vault path into a temp
// dir.
//
// Every test that reaches `ctl_read_vault_key` WITHOUT passing an explicit key —
// directly, or one level down through a params builder — must open a sandbox, for
// two distinct reasons:
//   1. it can then never write outside its own temp dir, and
//   2. a test named "without_vault_key" CREATES that condition (empty temp home,
//      HEIMDALL_VAULT_KEY unset) instead of inheriting it from the host, so the
//      suite passes identically whether or not a key is configured on the machine.
// Tests that pass the key and the configured flag as explicit arguments read no
// ambient state and deliberately do NOT take the sandbox.
//
// THREAD SAFETY, stated plainly: `os.set_env` mutates the whole process, so a
// sandbox is only isolating while it is the only one open. That is exactly what
// `vault_test_mutex` guarantees — so open the sandbox INSIDE the lock and let the
// deferred close run before the unlock. The temp dir is additionally unique per
// open, so two sandboxes can never share a path even if that discipline is broken
// later.
Ctl_Vault_Test_Sandbox :: struct {
	dir:       string,
	prev_home: string,
	had_home:  bool,
	prev_key:  string,
	had_key:   bool,

	// REQ-VAULT-2 added a key source: the local bridge, via agent.vault.get,
	// gated on these two variables. That makes them part of the ambient vault state
	// this sandbox exists to neutralise. Without them, a suite run from inside an
	// agent's own shell — where both ARE set — reaches the live bridge, receives a
	// real key, and encrypts where the test expects the no-key fallback. Nine
	// "without_vault_key" assertions failed exactly that way, in the same tree that
	// passed under `ham-ctl shell-cmd exec`, whose bridge-service environment has
	// neither variable set.
	prev_endpoint: string,
	had_endpoint:  bool,
	prev_token:    string,
	had_token:     bool,
}

ctl_vault_test_sandbox_counter: int

// Redirects the vault key path into a fresh temp dir and clears the ambient key
// env var. ALWAYS pair with `defer ctl_vault_test_sandbox_close(&sb)` so the
// redirect is undone on the assertion-failure path too — a leaked redirect would
// silently corrupt every sibling test that runs after it.
ctl_vault_test_sandbox_open :: proc(label: string) -> Ctl_Vault_Test_Sandbox {
	sb: Ctl_Vault_Test_Sandbox

	// pid-qualified and atomically counted: unique even across concurrent opens.
	n := sync.atomic_add(&ctl_vault_test_sandbox_counter, 1)
	tmp, _ := os.temp_dir(context.temp_allocator)
	sb.dir = fmt.aprintf("%s/heimdall-ctl-vault-test-%s-%d-%d", tmp, label, os.get_pid(), n)
	_ = os.make_directory_all(sb.dir)

	// Create the config dir the legacy key file would live in, so a test can plant
	// one there to prove it is ignored.
	cfg_dir := fmt.aprintf("%s/.config/heimdall", sb.dir)
	defer delete(cfg_dir)
	_ = os.make_directory_all(cfg_dir)

	// Capture PRESENCE, not just value: restoring an absent variable as "" would
	// turn "unset" into "set but empty" for every sibling test that follows.
	sb.prev_home, sb.had_home = os.lookup_env("HEIMDALL_HOME", context.allocator)
	sb.prev_key, sb.had_key = os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	sb.prev_endpoint, sb.had_endpoint = os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)
	sb.prev_token, sb.had_token = os.lookup_env("HEIMDALL_AGENT_TOKEN", context.allocator)

	_ = os.set_env("HEIMDALL_HOME", sb.dir)
	os.unset_env("HEIMDALL_VAULT_KEY")

	// The bridge source needs BOTH to be usable, so clearing both is belt-and-braces; it also
	// means a test that wants the bridge source can set them itself without fighting
	// a half-cleared environment.
	os.unset_env("HEIMDALL_BRIDGE_ENDPOINT")
	os.unset_env("HEIMDALL_AGENT_TOKEN")
	return sb
}

// Restores both variables to exactly the state they were in — re-set if they were
// present, unset if they were absent — then removes the temp dir.
ctl_vault_test_sandbox_close :: proc(sb: ^Ctl_Vault_Test_Sandbox) {
	if sb.had_home {
		_ = os.set_env("HEIMDALL_HOME", sb.prev_home)
	} else {
		os.unset_env("HEIMDALL_HOME")
	}
	delete(sb.prev_home)

	if sb.had_key {
		_ = os.set_env("HEIMDALL_VAULT_KEY", sb.prev_key)
	} else {
		os.unset_env("HEIMDALL_VAULT_KEY")
	}
	delete(sb.prev_key)

	if sb.had_endpoint {
		_ = os.set_env("HEIMDALL_BRIDGE_ENDPOINT", sb.prev_endpoint)
	} else {
		os.unset_env("HEIMDALL_BRIDGE_ENDPOINT")
	}
	delete(sb.prev_endpoint)

	if sb.had_token {
		_ = os.set_env("HEIMDALL_AGENT_TOKEN", sb.prev_token)
	} else {
		os.unset_env("HEIMDALL_AGENT_TOKEN")
	}
	delete(sb.prev_token)

	_ = os.remove_all(sb.dir)
	delete(sb.dir)
}

@(test)
test_vault_hex_validation :: proc(t: ^testing.T) {
	testing.expect(t, !is_valid_hex_key(""), "empty key should fail")
	testing.expect(t, !is_valid_hex_key("abcd"), "short key should fail")
	testing.expect(t, !is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef00"), "long key should fail")
	testing.expect(t, !is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"), "non-hex char 'g' should fail")
	testing.expect(t, is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), "lowercase 64-char hex should pass")
	testing.expect(t, is_valid_hex_key("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"), "uppercase 64-char hex should pass")
}

// REQ-T6-5: the legacy machine-wide ~/.config/heimdall/vault_key is no longer a
// key source. With a perfectly valid 0600 file present and no flag, no env and no
// bridge, ctl_read_vault_key must report "no key" rather than read the file.
@(test)
test_vault_legacy_key_file_is_ignored :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("legacy-file")
	defer ctl_vault_test_sandbox_close(&sb)

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	// The sandbox is only real if the path actually landed inside it. Check that
	// BEFORE writing, and bail out rather than continuing: testing.expect records a
	// failure but does NOT abort, so on a broken redirect the write below would
	// clobber the operator's real file.
	if !strings.has_prefix(path, sb.dir) {
		testing.expect(t, false, fmt.tprintf("vault key path must resolve inside the sandbox %s, got %s — refusing to write", sb.dir, path))
		return
	}

	content := strings.concatenate({test_key, "\n"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)content) == nil, "write legacy key file")
	_ = os.chmod(path, {.Read_User, .Write_User})

	_, ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, !ok, "a legacy ~/.config/heimdall/vault_key must be ignored when there is no env or bridge")

	// Ignored, not deleted: ctl leaves an existing file alone.
	testing.expect(t, os.exists(path), "the legacy file must be left on disk")

	// Explicit sources are unaffected: a valid flag still resolves, an invalid one
	// still rejects without falling through.
	args_good := [?]string{"ham-ctl", "issue", "list", "--vault-key", test_key}
	key, good_ok := ctl_read_vault_key(args_good[:], context.temp_allocator)
	testing.expect(t, good_ok, "a valid --vault-key must resolve")
	testing.expect_value(t, key, test_key)

	args_bad_flag := [?]string{"ham-ctl", "issue", "list", "--vault-key", "invalid_short_hex"}
	_, bad_flag_ok := ctl_read_vault_key(args_bad_flag[:], context.temp_allocator)
	testing.expect(t, !bad_flag_ok, "an invalid --vault-key must reject")

	_ = os.set_env("HEIMDALL_VAULT_KEY", "invalid_short_hex")
	_, bad_env_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, !bad_env_ok, "an invalid HEIMDALL_VAULT_KEY must reject")
}

// Every vault action other than `status` — including the removed key-writing,
// `show` and `clear` commands — is now an unknown command, and none may create the
// legacy file as a side effect.
@(test)
test_vault_removed_commands_do_not_touch_key_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("removed-cmds")
	defer ctl_vault_test_sandbox_close(&sb)

	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)
	if !strings.has_prefix(path, sb.dir) {
		testing.expect(t, false, fmt.tprintf("vault key path must resolve inside the sandbox %s, got %s", sb.dir, path))
		return
	}

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for action in ([]string{"set", "show", "clear", "write-key"}) {
		cmd := [?]string{"vault", action, test_key}
		args := [?]string{"ham-ctl", "vault", action, test_key}
		ctl_vault_command(cmd[:], args[:])
	}

	testing.expect(t, !os.exists(path), "no vault command may create ~/.config/heimdall/vault_key")
}

// `ham-ctl vault status` reports only the env override and the bridge's view.
@(test)
test_vault_status_sources :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("status")
	defer ctl_vault_test_sandbox_close(&sb)

	present, valid := ctl_vault_env_override()
	testing.expect(t, !present && !valid, "no HEIMDALL_VAULT_KEY means no env override")

	_ = os.set_env("HEIMDALL_VAULT_KEY", "invalid_short_hex")
	present, valid = ctl_vault_env_override()
	testing.expect(t, present && !valid, "a malformed HEIMDALL_VAULT_KEY is present but invalid")

	_ = os.set_env("HEIMDALL_VAULT_KEY", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	present, valid = ctl_vault_env_override()
	testing.expect(t, present && valid, "a 64-hex HEIMDALL_VAULT_KEY is a valid override")

	// Hub mode (no endpoint/token): the bridge cannot be asked.
	bridge := ctl_vault_status_bridge_json()
	defer delete(bridge)
	testing.expect_value(t, bridge, "{\"available\":false}")
}
