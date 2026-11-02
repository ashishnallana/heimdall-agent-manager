package main

// Self-healing provider extension install (F10, F12, ENR-12).
//
// bridge_extension_ensure brings one provider's Heimdall extension to the version
// this Bridge bundles. It is shared by the Hub `provider_extension_install` frame,
// the `extensions` step of `ham-bridge setup` and `ham-bridge extensions sync`
// (run by update). The provider binary and the bundle are always resolved
// locally; nothing a Hub frame names is ever executed.
//
// Before installing it classifies what is registered now:
//   current        installed, usable, >= expected version, from this bundle
//   other_bridge   installed, usable, >= expected, from another Heimdall Bridge's
//                  bundle under this OS user (REQ-MB-5: left alone, no ping-pong);
//                  when ours is the shared bundle, only a strictly newer one
//   ninjy_bundle   installed, usable, from another Heimdall Bridge's bundle (a
//                  profile's own copy or an older shared one) at most as new as
//                  our shared bundle: moved to the shared root, so that no single
//                  profile's uninstall can break it
//   absent         nothing registered: plain install
//   outdated       registered below the expected version
//   broken         disabled, errored, unknown version, or half-installed
//                  (marketplace registered without the plugin)
//   foreign        the marketplace points at another source (checkout, copy)
// Every class except current/other_bridge/absent is first removed (plugin
// uninstall + marketplace remove) and then added again from the bundle. A fresh
// install that fails or does not verify is retried once after the same cleanup,
// so the caller only sees an error once self-healing has been tried.
//
// Ensures of one provider are serialized per OS user (bridge_extension_lock):
// an update's `extensions sync` and the Hub's reconnect follow-up install would
// otherwise each clean up the other's fresh install. Classification happens
// after the lock is held, so the second caller finds the extension current.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

Bridge_Extension_Condition :: enum {
	Current,
	Other_Bridge,
	Ninjy_Bundle,
	Absent,
	Outdated,
	Broken,
	Foreign,
	Unknown, // not inspected (the install lock was not acquired)
}

BRIDGE_EXTENSION_CONDITION_NAMES := [Bridge_Extension_Condition]string {
	.Current      = "current",
	.Other_Bridge = "other_bridge",
	.Ninjy_Bundle = "ninjy_bundle",
	.Absent       = "absent",
	.Outdated     = "outdated",
	.Broken       = "broken",
	.Foreign      = "foreign",
	.Unknown      = "unknown",
}

// Where progress and discovery reports go: Hub frames, or setup events.
Bridge_Extension_Sink :: struct {
	profile: ^Provider_Profile,
	env: []string,
	data:     rawptr,
	progress: proc(data: rawptr, stage: string, pct: int, message: string),
	report:   proc(data: rawptr, results: []Bridge_Provider_Path),
}

Bridge_Extension_Result :: struct {
	ok:        bool,
	condition: Bridge_Extension_Condition, // what was found before any change
	action:    string, // ok: current | left | installed | reinstalled
	code:      string, // !ok: wire error code
	message:   string, // temp-allocated
	version:   string, // installed version afterwards (temp-allocated)
}

Bridge_Extension_Bundle_Resolver :: proc(provider: string, allocator := context.allocator) -> string
Bridge_Extension_Binary_Resolver :: proc(provider: string) -> (string, bool)

Bridge_Extension_Other_Profiles :: proc() -> int

// Local resolution only (F12); tests replace these.
bridge_extension_bundle_resolver: Bridge_Extension_Bundle_Resolver = bridge_get_bundled_extension_path
bridge_extension_binary_resolver: Bridge_Extension_Binary_Resolver = bridge_provider_resolve_path
bridge_extension_other_profiles: Bridge_Extension_Other_Profiles = bridge_extension_count_other_profiles

// bridge_extension_count_other_profiles counts the bridge profiles of this OS
// user other than this bridge's own (its data dir is <data root>/<service>).
// They share the provider registration, so it must outlive this profile.
bridge_extension_count_other_profiles :: proc() -> int {
	own := bridgesvc.pbase(strings.trim_space(bridge_config.data_dir))
	n := 0
	for name in bridgesvc.list_services(bridge_service_host()) do if name != own do n += 1
	return n
}

BRIDGE_CLAUDE_MARKETPLACE :: "heimdall"
BRIDGE_CODEX_MARKETPLACE :: "heimdall-codex"
BRIDGE_ANTIGRAVITY_PLUGIN :: "heimdall"

bridge_extension_canonical_provider :: proc(provider: string) -> string {
	p := strings.trim_space(provider)
	return "claude" if p == "claude-code" else p
}

bridge_extension_provider_supported :: proc(provider: string) -> bool {
	switch bridge_extension_canonical_provider(provider) {
	case "antigravity", "claude", "codex": return true
	}
	return false
}

bridge_extension_marketplace_name :: proc(provider: string) -> string {
	switch bridge_extension_canonical_provider(provider) {
	case "claude": return BRIDGE_CLAUDE_MARKETPLACE
	case "codex":  return BRIDGE_CODEX_MARKETPLACE
	}
	return ""
}

// bridge_extension_parse_marketplace finds marketplace `name` in the output of
// `claude plugin marketplace list --json` (an array of {name, path|installLocation})
// or `codex plugin marketplace list --json` ({marketplaces: [{name, root,
// marketplaceSource.source}]}). parsed is false when the output is not JSON.
bridge_extension_parse_marketplace :: proc(output, name: string, allocator := context.temp_allocator) -> (path: string, registered: bool, parsed: bool) {
	value, err := json.parse_string(output, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return "", false, false
	defer json.destroy_value(value, context.temp_allocator)
	items: json.Array
	#partial switch v in value {
	case json.Array:
		items = v
	case json.Object:
		list, ok := v["marketplaces"].(json.Array)
		if !ok do return "", false, false
		items = list
	case:
		return "", false, false
	}
	for item in items {
		obj, ok := item.(json.Object)
		if !ok do continue
		if n, _ := obj["name"].(json.String); string(n) != name do continue
		for key in ([]string{"path", "root", "installLocation"}) {
			if p, has := obj[key].(json.String); has && strings.trim_space(string(p)) != "" {
				return strings.clone(string(p), allocator), true, true
			}
		}
		if src, has := obj["marketplaceSource"].(json.Object); has {
			if p, ok_p := src["source"].(json.String); ok_p do return strings.clone(string(p), allocator), true, true
		}
		return "", true, true
	}
	return "", false, true
}

bridge_extension_normalize_path :: proc(path: string) -> string {
	if path == "" do return ""
	cleaned, err := filepath.clean(path, context.temp_allocator)
	p := cleaned if err == nil else path
	p, _ = strings.replace_all(p, "\\", "/", context.temp_allocator)
	p = strings.trim_right(p, "/")
	when ODIN_OS == .Windows do p = strings.to_lower(p, context.temp_allocator)
	return p
}

bridge_extension_same_path :: proc(a, b: string) -> bool {
	return bridge_extension_normalize_path(a) == bridge_extension_normalize_path(b)
}

// Another Bridge profile's managed bundle: <...>/heimdall/bridges/<service>/extensions.
bridge_extension_is_bridge_bundle :: proc(path: string) -> bool {
	p := bridge_extension_normalize_path(path)
	if !strings.has_suffix(p, "/extensions") do return false
	return strings.contains(strings.to_lower(p, context.temp_allocator), "/heimdall/bridges/")
}

// Every bridge profile (Ninjy account) of this OS user registers the provider
// extensions from one profile-neutral root with one directory per release:
// <data root>/.shared-extensions/<version>/extensions, next to the profiles'
// data dirs (<data root>/<service>). The path still matches
// bridge_extension_is_bridge_bundle, so bridges released before the shared root
// leave a usable registration there alone.
BRIDGE_SHARED_EXTENSIONS_DIR :: ".shared-extensions"

bridge_extension_is_shared_bundle :: proc(path: string) -> bool {
	p := strings.to_lower(bridge_extension_normalize_path(path), context.temp_allocator)
	return strings.contains(p, "/heimdall/bridges/" + BRIDGE_SHARED_EXTENSIONS_DIR + "/")
}

// bridge_extension_classify is pure: discovery state/version, the expected
// version, and where the provider's Heimdall marketplace points (if anywhere).
bridge_extension_classify :: proc(state, version, expected: string, mp_registered: bool, mp_path, our_root: string) -> Bridge_Extension_Condition {
	usable := state == "present" && version != "" && expected != "" &&
		bridge_provider_extension_version_compare(version, expected) >= 0
	if mp_registered && mp_path != "" && our_root != "" && !bridge_extension_same_path(mp_path, our_root) {
		if usable && bridge_extension_is_bridge_bundle(mp_path) {
			// Newest wins: a strictly newer bundle is left alone, anything else
			// moves to the shared root ours lives in.
			if bridge_extension_is_shared_bundle(our_root) && bridge_provider_extension_version_compare(version, expected) <= 0 do return .Ninjy_Bundle
			return .Other_Bridge
		}
		return .Foreign
	}
	if usable do return .Current
	switch state {
	case "absent", "":
		return .Broken if mp_registered else .Absent
	case "outdated":
		return .Outdated
	case "present":
		if version != "" && expected != "" do return .Outdated
	}
	return .Broken
}

// Commands that remove whatever is registered, in order; failures are expected
// (the plugin or marketplace may be missing) and ignored.
bridge_extension_cleanup_argvs :: proc(provider, bin_path: string, allocator := context.temp_allocator) -> [][]string {
	out := make([dynamic][]string, allocator)
	// Slice literals live on this proc's stack; clone each argv into allocator.
	add :: proc(out: ^[dynamic][]string, argv: []string, allocator: mem.Allocator) {
		append(out, slice.clone(argv, allocator))
	}
	switch bridge_extension_canonical_provider(provider) {
	case "claude":
		add(&out, {bin_path, "plugin", "uninstall", BRIDGE_CLAUDE_PLUGIN_ID}, allocator)
		add(&out, {bin_path, "plugin", "marketplace", "remove", BRIDGE_CLAUDE_MARKETPLACE}, allocator)
	case "codex":
		add(&out, {bin_path, "plugin", "remove", BRIDGE_CODEX_PLUGIN_ID}, allocator)
		add(&out, {bin_path, "plugin", "marketplace", "remove", BRIDGE_CODEX_MARKETPLACE}, allocator)
	case "antigravity":
		add(&out, {bin_path, "plugin", "uninstall", BRIDGE_ANTIGRAVITY_PLUGIN}, allocator)
	}
	return out[:]
}

// In-process half of the lock: POSIX record locks are per process, so two
// threads of one bridge would both "hold" the file lock.
@(private = "file")
g_extension_ensure_mu: [len(BRIDGE_EXTENSION_PROVIDERS)]sync.Mutex

BRIDGE_EXTENSION_LOCK_POLL :: 100 * time.Millisecond

// bridge_extension_lock waits until deadline for the provider's in-process
// mutex and its per-OS-user lock file. Release with bridge_extension_unlock.
bridge_extension_lock :: proc(prov: string, deadline: time.Time) -> (lock_path: string, ok: bool) {
	idx := -1
	for p, i in BRIDGE_EXTENSION_PROVIDERS do if p == prov do idx = i
	if idx < 0 do return "", true // unsupported; rejected later, nothing to serialize
	path, path_ok := bridge_extension_lock_path(prov)
	if !path_ok do return "", false
	for !sync.mutex_try_lock(&g_extension_ensure_mu[idx]) {
		if time.diff(time.now(), deadline) <= 0 do return "", false
		time.sleep(BRIDGE_EXTENSION_LOCK_POLL)
	}
	for !bridge_instance_lock(path) {
		if time.diff(time.now(), deadline) <= 0 {
			sync.mutex_unlock(&g_extension_ensure_mu[idx])
			return "", false
		}
		time.sleep(BRIDGE_EXTENSION_LOCK_POLL)
	}
	return path, true
}

bridge_extension_unlock :: proc(prov, lock_path: string) {
	bridge_instance_unlock(lock_path)
	for p, i in BRIDGE_EXTENSION_PROVIDERS do if p == prov do sync.mutex_unlock(&g_extension_ensure_mu[i])
}

bridge_extension_sink_progress :: proc(sink: Bridge_Extension_Sink, stage: string, pct: int, message: string) {
	if sink.progress != nil do sink.progress(sink.data, stage, pct, profile_redact_text(message,sink.profile))
}

bridge_extension_fail_result :: proc(cond: Bridge_Extension_Condition, code, message: string) -> Bridge_Extension_Result {
	return {ok = false, condition = cond, code = code, message = message}
}

// bridge_extension_ensure installs or repairs one provider's extension from
// ext_path with bin_path; both must come from local resolution.
bridge_extension_ensure :: proc(provider, ext_path, bin_path: string, deadline: time.Time, sink: Bridge_Extension_Sink) -> Bridge_Extension_Result {
	prov := bridge_extension_canonical_provider(provider)
	install_deadline := time.time_add(deadline, -8 * time.Second)
	lock_path, locked := bridge_extension_lock(prov, install_deadline)
	if !locked {
		return bridge_extension_fail_result(.Unknown, "busy",
			fmt.tprintf("another Ninjy extension install for %s is still running for this OS user; retry when it finishes", prov))
	}
	defer bridge_extension_unlock(prov, lock_path)
	// Runs before the unlock above: this bridge's own Codex plugin, enabled per
	// launch only (provider_extension_codex_own.odin). Best effort; without it
	// agents keep the shared release.
	// A bridge uninstalled without cleaning up leaves its own marketplace with a
	// deleted source, and Codex then fails every `plugin list`, including the
	// shared registration's check below: drop those first.
	if prov == "codex" && sink.profile == nil {
		if healed, heal_msg := bridge_codex_own_heal_hook(); healed > 0 || heal_msg != "" {
			bridge_extension_sink_progress(sink, "installing", 5, fmt.tprintf("Removed %d stale bridge Codex marketplace(s)%s%s", healed, "; " if heal_msg != "" else "", heal_msg))
		}
	}
	defer if prov == "codex" && sink.profile == nil {
		own_ok, own_msg := bridge_codex_own_ensure_hook(bin_path, install_deadline, sink.env)
		bridge_extension_sink_progress(sink, "installing", 90, own_ok ? own_msg : fmt.tprintf("This bridge's own Codex plugin was not registered (%s); agents use the shared one", own_msg))
	}
	bundled_version := bridge_provider_extension_read_manifest_version(ext_path, prov)
	required_version := bridge_extension_required_version(prov)
	// Verification needs the newer of the bundled manifest and the catalog minimum.
	expected_version := bundled_version
	if required_version != "" && bundled_version != "" && bridge_provider_extension_version_compare(required_version, bundled_version) > 0 {
		expected_version = required_version
	}

	mp_root := ""
	has_mp := false
	switch prov {
	case "claude": mp_root, has_mp = bridge_claude_resolve_marketplace_root(ext_path)
	case "codex":  mp_root, has_mp = bridge_codex_resolve_marketplace_root(ext_path)
	}

	// Inspect what is registered now.
	pre_state, pre_version := "absent", ""
	pre := bridge_extension_discover_scoped(prov,sink)
	for r in pre {
		if r.provider != prov do continue
		pre_state = strings.clone(r.extension_state, context.temp_allocator)
		pre_version = strings.clone(r.extension_version, context.temp_allocator)
		break
	}
	mp_path, mp_registered := "", false
	if mp_name := bridge_extension_marketplace_name(prov); mp_name != "" {
		out, _, listed := bridge_extension_install_step({bin_path, "plugin", "marketplace", "list", "--json"}, install_deadline, sink.env)
		if listed do mp_path, mp_registered, _ = bridge_extension_parse_marketplace(out, mp_name)
	}
	cond := bridge_extension_classify(pre_state, pre_version, expected_version, mp_registered, mp_path, mp_root)
	if cond == .Current || cond == .Other_Bridge {
		if sink.report != nil do sink.report(sink.data, pre[:])
		bridge_provider_paths_destroy_all(&pre)
		msg := fmt.tprintf("Provider extension %s is already installed (bundled %s); registration left unchanged", pre_version, expected_version)
		if cond == .Other_Bridge do msg = fmt.tprintf("Provider extension %s is registered by another Ninjy Bridge (%s); left unchanged", pre_version, mp_path)
		return {ok = true, condition = cond, action = "current" if cond == .Current else "left", message = msg, version = pre_version}
	}
	bridge_provider_paths_destroy_all(&pre)

	// A bundle older than the catalog minimum cannot satisfy verification.
	if required_version != "" && bundled_version != "" && bridge_provider_extension_version_compare(bundled_version, required_version) < 0 {
		return bridge_extension_fail_result(cond, "bundled_extension_outdated",
			fmt.tprintf("bundled %s extension at %s is version %q, but Ninjy requires %q or newer; update this Bridge to a release that bundles extension %s, then retry",
				prov, ext_path, bundled_version, required_version, required_version))
	}
	if (prov == "claude" || prov == "codex") && !has_mp {
		label := "Claude marketplace metadata (.claude-plugin/marketplace.json)" if prov == "claude" else "Codex marketplace metadata"
		return bridge_extension_fail_result(cond, "missing_marketplace", fmt.tprintf("missing %s for extension directory: %s", label, ext_path))
	}

	cleanup := cond != .Absent
	last_code, last_message := "", ""
	for attempt in 0..<2 {
		if attempt > 0 {
			// Self-heal: the plain install did not take; remove and add again.
			if time.diff(time.now(), install_deadline) <= 0 do break
			cleanup = true
		}
		if cleanup {
			bridge_extension_sink_progress(sink, "installing", 20,
				fmt.tprintf("Removing the existing %s extension registration (%s) before reinstalling from the bundle...", prov,
					BRIDGE_EXTENSION_CONDITION_NAMES[cond] if attempt == 0 else last_code))
			for argv in bridge_extension_cleanup_argvs(prov, bin_path) do _, _, _ = bridge_extension_install_step(argv, install_deadline, sink.env)
		}
		code, message, installed := bridge_extension_install_once(prov, ext_path, bin_path, mp_root, install_deadline, sink)
		if !installed {
			last_code, last_message = code, message
			if !cleanup do continue
			return bridge_extension_fail_result(cond, code, message)
		}
		bridge_extension_sink_progress(sink, "installing", 80, "Verifying installed extension status...")
		results := bridge_extension_discover_scoped(prov,sink)
		if sink.report != nil do sink.report(sink.data, results[:])
		verified := false
		actual_state, actual_version := "absent", ""
		for r in results {
			if r.provider != prov do continue
			actual_state = strings.clone(r.extension_state, context.temp_allocator)
			actual_version = strings.clone(r.extension_version, context.temp_allocator)
			verified = r.state == "present" && r.extension_state == "present" &&
				expected_version != "" && actual_version != "" &&
				bridge_provider_extension_version_compare(actual_version, expected_version) >= 0
			break
		}
		bridge_provider_paths_destroy_all(&results)
		if time.diff(time.now(), deadline) <= 0 {
			return bridge_extension_fail_result(cond, "timed_out", "extension installation timed out during status verification")
		}
		if verified {
			return {ok = true, condition = cond, action = "reinstalled" if cleanup else "installed", version = actual_version,
				message = fmt.tprintf("Provider extension %s %s from %s", actual_version, "reinstalled" if cleanup else "installed", ext_path)}
		}
		last_code = "verify_failed"
		last_message = fmt.tprintf("extension installation verification failed: state is %q, version is %q (required %q or newer, bundled %q)",
			actual_state, actual_version, expected_version, bundled_version)
		if cleanup do break
	}
	return bridge_extension_fail_result(cond, last_code if last_code != "" else "timed_out", last_message if last_message != "" else "extension installation timed out")
}

// bridge_extension_remove uninstalls one provider's Ninjy extension with bin_path
// (local resolution only): plugin uninstall and marketplace removal (failures are
// expected when parts are already gone), then a fresh discovery, reported to the
// sink, that must no longer find the extension. Setup and update reinstall it.
bridge_extension_remove :: proc(provider, bin_path: string, deadline: time.Time, sink: Bridge_Extension_Sink) -> Bridge_Extension_Result {
	prov := bridge_extension_canonical_provider(provider)
	install_deadline := time.time_add(deadline, -8 * time.Second)
	lock_path, locked := bridge_extension_lock(prov, install_deadline)
	if !locked {
		return bridge_extension_fail_result(.Unknown, "busy",
			fmt.tprintf("another Ninjy extension install for %s is still running for this OS user; retry when it finishes", prov))
	}
	defer bridge_extension_unlock(prov, lock_path)
	// This bridge's own Codex plugin is never shared with another profile.
	if prov == "codex" && sink.profile == nil do bridge_codex_own_remove_hook(bin_path, install_deadline, sink.env)
	// The OS user's registration is shared by every profile of this OS user;
	// removing it for one Ninjy account would break the others' agents. A
	// per-account provider profile registers in its own config dir instead.
	if others := bridge_extension_other_profiles(); sink.profile == nil && others > 0 {
		return {ok = true, condition = .Unknown, action = "left",
			message = fmt.tprintf("Provider extension for %s left installed: %d other Ninjy Bridge profile(s) on this OS user still use it", prov, others)}
	}
	bridge_extension_sink_progress(sink, "uninstalling", 20, fmt.tprintf("Removing the %s extension and its marketplace registration...", prov))
	for argv in bridge_extension_cleanup_argvs(prov, bin_path) do _, _, _ = bridge_extension_install_step(argv, install_deadline, sink.env)
	bridge_extension_sink_progress(sink, "uninstalling", 80, "Verifying the extension is gone...")
	// A marketplace source that survives `marketplace remove` (another config
	// layer, a CLI that refused) would make the next install fail with "already
	// added from a different source": name it instead of reporting success.
	if mp_name := bridge_extension_marketplace_name(prov); mp_name != "" {
		out, _, listed := bridge_extension_install_step({bin_path, "plugin", "marketplace", "list", "--json"}, install_deadline, sink.env)
		if listed {
			if mp_path, still, _ := bridge_extension_parse_marketplace(out, mp_name); still {
				return bridge_extension_fail_result(.Unknown, "marketplace_remove_failed",
					fmt.tprintf("the %s marketplace %q is still registered (source %q) after `%s plugin marketplace remove %s`; remove it from the provider's config, then retry",
						prov, mp_name, mp_path, prov, mp_name))
			}
		}
	}
	results := bridge_extension_discover_scoped(prov,sink)
	if sink.report != nil do sink.report(sink.data, results[:])
	state := "absent"
	for r in results do if r.provider == prov do state = strings.clone(r.extension_state, context.temp_allocator)
	bridge_provider_paths_destroy_all(&results)
	if state == "present" || state == "outdated" || state == "disabled" {
		return bridge_extension_fail_result(.Unknown, "uninstall_failed",
			fmt.tprintf("the %s extension is still registered after uninstall (state %q); remove it with the provider CLI", prov, state))
	}
	return {ok = true, condition = .Absent, action = "uninstalled", message = fmt.tprintf("Provider extension for %s uninstalled", prov)}
}

// bridge_extension_install_once registers the bundled marketplace (claude,
// codex) and installs the plugin.
@(private = "file")
bridge_extension_install_once :: proc(prov, ext_path, bin_path, mp_root: string, install_deadline: time.Time, sink: Bridge_Extension_Sink) -> (code, message: string, ok: bool) {
	if prov == "claude" || prov == "codex" {
		bridge_extension_sink_progress(sink, "installing", 25, fmt.tprintf("Registering %s local plugin marketplace...", "Claude" if prov == "claude" else "Codex"))
		_, msg, registered := bridge_extension_install_step({bin_path, "plugin", "marketplace", "add", mp_root}, install_deadline, sink.env)
		// Another source holds the name (e.g. an older Bridge's bundle): replace it
		// here instead of depending on a second, possibly time-starved attempt.
		if !registered && strings.contains(strings.to_lower(msg, context.temp_allocator), "different source") {
			bridge_extension_sink_progress(sink, "installing", 30, "Replacing a marketplace registered from another source...")
			_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", bridge_extension_marketplace_name(prov)}, install_deadline, sink.env)
			_, msg, registered = bridge_extension_install_step({bin_path, "plugin", "marketplace", "add", mp_root}, install_deadline, sink.env)
		}
		if !registered do return "marketplace_add_failed", msg, false
	}
	bridge_extension_sink_progress(sink, "installing", 50, "Executing provider extension installation...")
	argv := bridge_provider_extension_build_install_args(prov, bin_path, ext_path)
	output, install_error, installed := bridge_extension_install_step(argv, install_deadline, sink.env)
	if !installed do return "install_failed", install_error, false
	if prov == "claude" && strings.contains(strings.to_lower(output, context.temp_allocator), "already installed") {
		bridge_extension_sink_progress(sink, "installing", 65, "Updating existing Claude extension...")
		_, msg, updated := bridge_extension_install_step({bin_path, "plugin", "update", BRIDGE_CLAUDE_PLUGIN_ID}, install_deadline, sink.env)
		if !updated do return "update_failed", msg, false
	}
	return "", "", true
}

bridge_provider_paths_destroy_all :: proc(results: ^[dynamic]Bridge_Provider_Path) {
	for &result in results do bridge_provider_path_destroy(&result)
	delete(results^)
	results^ = nil
}

bridge_extension_discover_scoped :: proc(prov: string, sink: Bridge_Extension_Sink) -> [dynamic]Bridge_Provider_Path {
	if sink.profile == nil do return bridge_extension_discover({prov})
	return bridge_provider_discover_execute_profile({prov},sink.profile.profile_id)
}
