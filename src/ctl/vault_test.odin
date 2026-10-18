package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Serialises every test that touches AMBIENT vault state — the HEIMDALL_HOME /
// HEIMDALL_VAULT_KEYRING environment and the vault key file they resolve to. Those
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
//      HEIMDALL_VAULT_KEYRING unset) instead of inheriting it from the host, so the
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
	sb.prev_key, sb.had_key = os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	sb.prev_endpoint, sb.had_endpoint = os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)
	sb.prev_token, sb.had_token = os.lookup_env("HEIMDALL_AGENT_TOKEN", context.allocator)

	_ = os.set_env("HEIMDALL_HOME", sb.dir)
	os.unset_env("HEIMDALL_VAULT_KEYRING")

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
		_ = os.set_env("HEIMDALL_VAULT_KEYRING", sb.prev_key)
	} else {
		os.unset_env("HEIMDALL_VAULT_KEYRING")
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

