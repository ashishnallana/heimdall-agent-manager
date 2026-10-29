package main

// `ham-bridge update --bundle DIR [--hub URL [--profile P] | --service NAME]
// [--json-progress] [--detach]`: update an installed profile from an unpacked,
// verified release bundle. The NEW binary runs `setup` for the profile
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

BRIDGE_UPDATE_USAGE :: "usage: ham-bridge update --bundle DIR [--hub URL [--profile P] | --service NAME] [--json-progress] [--detach]"

bridge_update_command :: proc(args: []string) -> bool {
	bundle := strings.trim_space(option_value(args, "--bundle", ""))
	if bundle == "" {
		if option_value(args, "--version", "") != "" {
			fmt.eprintln("ham-bridge update: --version is not supported yet; download and verify the release bundle and pass --bundle DIR (or update from Heimdall: Settings -> Bridges -> Update)")
		} else {
			fmt.eprintln(BRIDGE_UPDATE_USAGE)
		}
		return false
	}
	host := bridge_service_host()
	name, err := bridge_service_resolve(host, args)
	if name == "" {
		fmt.eprintln("ham-bridge update:", err)
		return false
	}
	l := bridgesvc.layout_for(host, name)
	hub := bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE))
	if hub == "" do hub = bridgesvc.hub_from_config(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE))
	if hub == "" {
		fmt.eprintfln("ham-bridge update: %s records no hub; run ham-bridge setup --hub <url>", l.state_dir)
		return false
	}
	profile := bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.PROFILE_FILE))
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
	argv := bridgesvc.update_setup_argv(exe, hub, profile, has_flag(args, "--json-progress"))
	own, _ := os.lookup_env("HEIMDALL_BRIDGE_SERVICE_NAME", context.temp_allocator)
	if has_flag(args, "--detach") || strings.trim_suffix(own, ".service") == name {
		if !bridge_os_spawn_new_session(argv) {
			fmt.eprintln("ham-bridge update: cannot start the detached update")
			return false
		}
		fmt.printfln("ham-bridge update: updating %s to %s in the background (ham-bridge status shows the result)", name, strings.trim_space(out))
		return true
	}
	return bridge_setup_exec_inherit(argv)
}
