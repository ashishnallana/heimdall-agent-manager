package main

// BR-1: bridge-side, pre-spawn bootstrap materialization (Option A).
//
// In the wrapper-free runtime the bridge — not a ham-wrapper — is the sole writer
// of an agent's run_dir. Before spawning the agent under ham-pty-host the bridge:
//
//   1. CLEAN-SLATES the run_dir: recursively remove it, then recreate it empty.
//      This ports the wrapper's clean-slate guarantee (wrapper_bootstrap_rmdir_all
//      in src/wrapper/bootstrap.odin): no stale file (an old CLAUDE.md, a removed
//      skill, a superseded ham-ctl shim) can ever survive a relaunch, regardless
//      of why the previous run ended.
//   2. MATERIALIZES the bootstrap by reusing the existing assembly path
//      bridge_bootstrap_fetch_and_materialize (AGENTS.md, skills, the rendered
//      ham-ctl shim, and heimdall-bootstrap-manifest.json).
//   3. BUILDS the HEIMDALL_* environment map the agent process inherits, so the
//      in-run-dir ham-ctl shim and the agent both resolve the bridge endpoint,
//      their agent token, the instance id, and the ctl binary.
//
// This runs on every (re)launch: a restart re-materializes from a clean slate.
// There is no wrapper and no wrapper.bootstrap.* RPC in this path.

import "core:os"
import "core:strings"
import agent_runtime "odin_test:lib/agent_runtime"

// Bridge_Prespawn_Result carries the materialized run_dir plus the environment
// the agent process must inherit. env is a slice of "KEY=VALUE" entries (the
// shape ham-pty-host's spawn --env consumes); the caller owns the slice and each
// string.
Bridge_Prespawn_Result :: struct {
	run_dir: string,
	env:     []string,
}

// bridge_prespawn_materialize clean-slates run_dir then materializes the bootstrap
// for instance_id, returning the run_dir + HEIMDALL_* env on success. It reuses
// bridge_bootstrap_fetch_and_materialize for assembly; a false return means the
// hub fetch/assembly failed (the run_dir has already been reset to empty and is
// safe to retry). The caller owns result.run_dir and result.env.
bridge_prespawn_materialize :: proc(hub_url, bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider: string) -> (Bridge_Prespawn_Result, bool) {
	clean := strings.trim_right(run_dir, "/")
	if strings.trim_space(clean) == "" do return Bridge_Prespawn_Result{}, false

	// Nuke then recreate — guarantees a clean slate on every (re)launch.
	bridge_prespawn_clean_slate(clean)

	if !bridge_bootstrap_fetch_and_materialize(hub_url, bridge_token, instance_id, clean, bridge_endpoint, agent_token, provider) {
		return Bridge_Prespawn_Result{}, false
	}
	return Bridge_Prespawn_Result{
		run_dir = strings.clone(clean),
		env = bridge_prespawn_env(clean, bridge_endpoint, agent_token, instance_id),
	}, true
}

// bridge_prespawn_clean_slate removes the entire run_dir tree then recreates it
// empty. Split out so tests can exercise the clean-slate guarantee without a hub.
bridge_prespawn_clean_slate :: proc(run_dir: string) {
	dir := strings.trim_right(run_dir, "/")
	if strings.trim_space(dir) == "" do return
	bridge_prespawn_rmdir_all(dir)
	_ = bridge_make_directory_all(dir)
}

// bridge_prespawn_rmdir_all removes the entire directory tree rooted at dir
// (best-effort, depth-first). Ported from the wrapper's wrapper_bootstrap_rmdir_all.
// The run_dir is recreated immediately after by the caller so a partial removal is
// harmless.
bridge_prespawn_rmdir_all :: proc(dir: string) {
	fd, err := os.open(dir)
	if err != nil do return
	infos, rerr := os.read_dir(fd, -1, context.allocator)
	os.close(fd)
	if rerr == nil {
		for info in infos {
			full := strings.concatenate({dir, "/", info.name})
			if info.type == .Directory {
				bridge_prespawn_rmdir_all(full)
			} else {
				_ = os.remove(full)
			}
			delete(full)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	_ = os.remove(dir)
}

// bridge_prespawn_env builds the HEIMDALL_* environment the agent process (and the
// in-run-dir ham-ctl shim) inherit, as "KEY=VALUE" entries:
//   HEIMDALL_BRIDGE_ENDPOINT   — local bridge socket the ctl shim dials
//   HEIMDALL_AGENT_TOKEN       — this instance's agent token
//   HEIMDALL_AGENT_INSTANCE_ID — the agent instance id
//   HEIMDALL_CTL_BIN           — absolute path to the materialized ham-ctl shim
//
// The vault keyring is deliberately NOT injected here. It used to be, but the env is
// built once at spawn and never refreshed, so after an operator rotates the key a
// running agent's env held the OLD value — and because ctl checks
// $HEIMDALL_VAULT_KEYRING before asking the bridge, that stale value WON over the
// correct key and decryption failed silently for the rest of the instance's
// life. ctl now resolves the key at invocation time from this bridge via
// agent.vault.get (the bridge holds a per-bridge key in the keyring/Keychain),
// so it is always live; $HEIMDALL_VAULT_KEYRING remains only as an explicit override.
//
// The caller owns the returned slice and each string.
bridge_prespawn_env :: proc(run_dir, bridge_endpoint, agent_token, instance_id: string) -> []string {
	ctl_bin := bridge_prespawn_ctl_bin_path(run_dir)
	defer delete(ctl_bin)
	out := make([dynamic]string)
	append(&out, strings.concatenate({"HEIMDALL_BRIDGE_ENDPOINT=", bridge_endpoint}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_TOKEN=", agent_token}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_INSTANCE_ID=", instance_id}))
	append(&out, strings.concatenate({"HEIMDALL_CTL_BIN=", ctl_bin}))
	return out[:]
}

// bridge_prespawn_ctl_bin_path is the run-dir-relative location the ham-ctl shim
// is materialized at (see bridge_bootstrap_write_ham_ctl_wrapper). Kept here so the
// env map and the materializer agree on the path.
bridge_prespawn_ctl_bin_path :: proc(run_dir: string) -> string {
	return strings.concatenate({strings.trim_right(run_dir, "/"), "/", agent_runtime.CTL_SHIM_PATH})
}

// bridge_prespawn_result_delete frees an owned Bridge_Prespawn_Result.
bridge_prespawn_result_delete :: proc(r: Bridge_Prespawn_Result) {
	if r.run_dir != "" do delete(r.run_dir)
	for e in r.env do delete(e)
	if r.env != nil do delete(r.env)
}
