package main

// `ham-bridge update (--bundle DIR | --version TAG|latest) [--hub URL [--profile P]
// | --service NAME] [--json-progress] [--detach]`: update an installed profile from
// an unpacked, verified release bundle. --version downloads it first: resolve the
// GitHub release, SHA-256 verify the bundle against its SHA256SUMS and unpack it
// (release_fetch.odin); an unknown or unverifiable release changes nothing. The NEW binary runs `setup` for the profile
// (bridgesvc.update_setup_argv), whose transaction stages, keeps bin.bak,
// re-renders the service, refreshes provider extensions on every OS (Windows
// included), restarts and waits for running + connected to the hub, and rolls back
// to bin.bak and restarts the old bridge when any of that fails.
//
// --detach (implied when this runs inside the service being updated) starts the
// update in a session of its own and returns at once, so stopping the service does
// not stop the update.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

BRIDGE_UPDATE_USAGE :: "usage: ham-bridge update (--bundle DIR | --version TAG|latest) [--hub URL [--profile P] | --service NAME] [--json-progress] [--detach]"

bridge_update_command :: proc(args: []string) -> bool {
	bundle := strings.trim_space(option_value(args, "--bundle", ""))
	version := strings.trim_space(option_value(args, "--version", ""))
	if (bundle == "") == (version == "") {
		fmt.eprintln(BRIDGE_UPDATE_USAGE)
		return false
	}
	host := bridge_service_host()
	name, err := bridge_service_resolve(host, args)
	if name == "" {
		fmt.eprintln("ham-bridge update:", err)
		return false
	}
	l := bridgesvc.layout_for(host, name)
	automatic := has_flag(args, "--auto-worker")
	automatic_success := false
	auto_lock := bridge_auto_update_lock_path()
	auto_locked := false
	defer if auto_locked do bridge_instance_unlock(auto_lock)
	defer if automatic do bridge_auto_update_finish(name, automatic_success)
	if automatic {
		if !bridge_auto_update_enabled(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)) do return false
		if !bridge_instance_lock(auto_lock) do return false
		auto_locked = true
	}
	hub := bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE))
	if hub == "" do hub = bridgesvc.hub_from_config(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE))
	if hub == "" {
		fmt.eprintfln("ham-bridge update: %s records no hub; run ham-bridge setup --hub <url>", l.state_dir)
		return false
	}
	profile := bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.PROFILE_FILE))
	if version != "" {
		target, blocked := bridge_release_target()
		if blocked {
			fmt.eprintfln("ham-bridge update: this binary was not built for this platform (%s); reinstall with the matching bundle", target)
			return false
		}
		// Under the profile's data dir, not the system temp dir: a detached update
		// outlives this process and still reads the unpacked bundle.
		work := bridgesvc.pjoin(l.data_dir, "updates", "release")
		_ = os.remove_all(work)
		if bridge_make_directory_all(work) != nil {
			fmt.eprintfln("ham-bridge update: cannot create %s", work)
			return false
		}
		fmt.printfln("ham-bridge update: resolving release %s for %s...", version, target)
		dir, tag, ferr := bridge_release_fetch(version, target, work)
		if ferr != "" {
			_ = os.remove_all(work)
			fmt.eprintfln("ham-bridge update: %s; nothing was changed", ferr)
			return false
		}
		fmt.printfln("ham-bridge update: %s downloaded and SHA-256 verified", tag)
		bundle = dir
	}
	exe := bridgesvc.update_bundle_exe(host, bundle, proc(p: string) -> bool {return os.is_file(p)})
	if exe == "" {
		fmt.eprintfln("ham-bridge update: %s has no %s (looked in it and in its bin/)", bundle, bridgesvc.exe_name(host, "ham-bridge"))
		return false
	}
	// Preflight: a binary that does not even run is refused before anything stops.
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	out, errout, ran, _ := bridge_process_run_capture({exe, "--version"}, 5 * time.Second)
	defer {delete(out); delete(errout)}
	if !ran {
		fmt.eprintfln("ham-bridge update: %s --version failed; nothing was changed", exe)
		return false
	}
	if automatic {
		fields := strings.fields(out, context.temp_allocator)
		installed := bridgesvc.pjoin(l.bin_dir, bridgesvc.exe_name(host, "ham-bridge"))
		current, current_err, current_ok, _ := bridge_process_run_capture({installed, "--version"}, 5 * time.Second)
		defer {delete(current); delete(current_err)}
		current_fields := strings.fields(current, context.temp_allocator)
		if !current_ok || len(fields) < 2 || len(current_fields) < 2 || !bridge_auto_update_newer(fields[1], current_fields[1]) do return false
		if !bridge_auto_update_enabled(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)) do return false
	}
	argv := bridgesvc.update_setup_argv(exe, hub, profile, has_flag(args, "--json-progress"))
	own, _ := os.lookup_env("HEIMDALL_BRIDGE_SERVICE_NAME", context.temp_allocator)
	if !automatic && (has_flag(args, "--detach") || strings.trim_suffix(own, ".service") == name) {
		if !bridge_os_spawn_new_session(argv) {
			fmt.eprintln("ham-bridge update: cannot start the detached update")
			return false
		}
		fmt.printfln("ham-bridge update: updating %s to %s in the background (ham-bridge status shows the result)", name, strings.trim_space(out))
		return true
	}
	result := bridge_setup_exec_inherit(argv)
	automatic_success = result
	return result
}
