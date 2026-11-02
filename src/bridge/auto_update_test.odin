package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import httpc "odin_test:lib/httpc"

@(test)
test_auto_update_schedule_and_backoff :: proc(t: ^testing.T) {
	for failures in 0..<10 {
		low := bridge_auto_update_delay(failures, 0)
		high := bridge_auto_update_delay(failures, u64((low / 9) * 2))
		testing.expect(t, low >= BRIDGE_AUTO_UPDATE_INTERVAL * 9 / 10)
		testing.expect(t, high <= BRIDGE_AUTO_UPDATE_INTERVAL * 16 * 11 / 10)
		if failures > 1 do testing.expect(t, low >= bridge_auto_update_delay(failures - 1, 0))
	}
	testing.expect(t, bridge_auto_update_delay(0, 0) != bridge_auto_update_delay(0, 123456), "profiles get different jitter")
	testing.expect_value(t, bridge_auto_update_delay(50, 0), bridge_auto_update_delay(5, 0))
	testing.expect(t, bridge_auto_update_newer("v2.0.0", "1.99.99"))
	testing.expect(t, !bridge_auto_update_newer("v1.2.3", "1.2.3"))
	testing.expect(t, !bridge_auto_update_newer("1.2.2", "1.2.3"))
	testing.expect(t, !bridge_auto_update_newer("../v9", "1.0"))
}

@(test)
test_auto_update_config_preserves_profile_settings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for original in ([]string{
		"[daemon]\ndaemon_id = \"account-a\"\n",
		"[bridge]\nfs_root = \"/work\"\n[wrapper]\ndaemon_url = \"https://example.test\"\n",
		"[bridge]\nauto_update_enabled = true # comment\n[wrapper]\nauto_update_enabled = true\n",
		"[bridge] # a commented table heading\nauto_update_enabled = true\n",
	}) {
		updated := bridge_auto_update_config_text(original, false)
		if strings.contains(original, "[bridge]") do testing.expect_value(t, strings.count(updated, "[bridge]"), 1)
		cfg: cfg_lib.Config
		cfg_lib.parse_config(updated, &cfg)
		testing.expect(t, cfg.bridge.auto_update_configured && !cfg.bridge.auto_update_enabled)
		if strings.contains(original, "account-a") do testing.expect_value(t, cfg.daemon.daemon_id, "account-a")
		if strings.contains(original, "fs_root") do testing.expect_value(t, cfg.bridge.fs_root, "/work")
		if strings.contains(original, "[wrapper]\nauto_update_enabled") do testing.expect(t, strings.contains(updated, "[wrapper]\nauto_update_enabled = true"))
		cfg_lib.parse_config(bridge_auto_update_config_text(updated, true), &cfg)
		testing.expect(t, cfg.bridge.auto_update_enabled)
	}
}

auto_test_version: string
auto_test_spawns: int
auto_test_busy: bool
auto_test_busy_during_lookup: bool
auto_test_service: string
auto_test_mutex: sync.Mutex

auto_test_resolve :: proc() -> string {
	if auto_test_busy_during_lookup do auto_test_busy = true
	return strings.clone(auto_test_version)
}
auto_test_quiet :: proc(reserve: bool) -> bool {return !auto_test_busy}
auto_test_spawn :: proc(argv: []string) -> bool {
	auto_test_spawns += 1
	auto_test_service = strings.clone(argv[5], context.temp_allocator)
	return true
}

@(test)
test_auto_update_tick_quiet_profile_backoff_optout :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	dir := fmt.tprintf("%s/auto-update-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	_ = bridge_make_directory_all(dir)
	defer os.remove_all(dir)
	path, config := fmt.tprintf("%s/auto.json", dir), fmt.tprintf("%s/config.toml", dir)
	testing.expect(t, os.write_entire_file(config, transmute([]byte)string("[bridge]\n")) == nil)
	testing.expect(t, bridge_auto_update_enabled(config), "default on for existing profiles")
	testing.expect(t, !bridge_auto_update_enabled(fmt.tprintf("%s/absent", dir)))
	auto_test_spawns = 0
	auto_test_version = "v999.0.0"
	auto_test_busy = false
	auto_test_busy_during_lookup = false
	quiet: i64
	bridge_auto_update_tick("profile-a", config, path, &quiet, 1000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	state := bridge_auto_update_read(path)
	testing.expect(t, state.next_check_ms > 1000)
	testing.expect_value(t, auto_test_spawns, 0)
	now := state.next_check_ms
	auto_test_busy = true
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, quiet, i64(0))
	auto_test_busy = false
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 1, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 30_000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 0)
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 60_001, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_service, "profile-a")
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.failures, 1)
	testing.expect_value(t, state.pending_version, "v999.0.0")
	// A crashed/rolled-back worker leaves a durable future retry and failed attempt.
	quiet = now
	bridge_auto_update_tick("profile-a", config, path, &quiet, state.next_check_ms - 1, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 1)
	now = state.next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.failures, 2)
	testing.expect(t, state.next_check_ms - now >= BRIDGE_AUTO_UPDATE_INTERVAL * 18 / 10)
	// An equal or older target never spawns an updater, even after the quiet window.
	for version in ([]string{contracts.APP_VERSION, "v0.0.0"}) {
		auto_test_version = version
		now = state.next_check_ms
		quiet = now - 60_000
		bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
		state = bridge_auto_update_read(path)
		testing.expect_value(t, auto_test_spawns, 2)
	}
	auto_test_version = "v999.0.0"
	auto_test_busy_during_lookup = true
	now = state.next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 2)
	testing.expect(t, bridge_auto_update_read(path).next_check_ms == now, "a new agent during lookup does not incur failure backoff")
	auto_test_busy_during_lookup = false
	auto_test_busy = false
	testing.expect(t, os.write_entire_file(config, transmute([]byte)string("[bridge]\nauto_update_enabled = false\n")) == nil)
	now = state.next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 2)
	testing.expect_value(t, quiet, i64(0))
	// Failed verification/rollback keeps the persisted failure count; success
	// resets it only after the setup transaction returns successfully.
	state.failures = 3
	state.pending_version = "v999.0.0"
	testing.expect(t, bridge_auto_update_write(path, state))
	bridge_auto_update_finish_at(path, false, now, 0)
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.failures, 3)
	testing.expect_value(t, state.pending_version, "")
	testing.expect(t, state.next_check_ms - now > BRIDGE_AUTO_UPDATE_INTERVAL * 3)
	bridge_auto_update_finish_at(path, true, now, 0)
	testing.expect_value(t, bridge_auto_update_read(path).failures, 0)
}

@(test)
test_auto_update_resolve_hub_catalog :: proc(t: ^testing.T) {
	version := bridge_auto_update_resolve(proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
		return hub_test_response(200, `{"data":{"latest_version":"v999.0.0","artifact_available":true}}`), .None
	}, proc(url: string) -> (string, bool, string) {return "", false, "GitHub must not be used"})
	defer delete(version)
	testing.expect_value(t, version, "v999.0.0")
}

@(test)
test_auto_update_resolve_github_fallback :: proc(t: ^testing.T) {
	target, blocked := bridge_release_target()
	testing.expectf(t, !blocked, "fixture target %s must permit updates", target)
	version := bridge_auto_update_resolve(proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
		return hub_test_response(503, "unavailable"), .None
	}, proc(url: string) -> (string, bool, string) {
		target, _ := bridge_release_target()
		bundle := bridge_release_bundle_name(target, "v999.0.0")
		doc := strings.concatenate({`[{"tag_name":"v999.0.0","draft":false,"prerelease":false,"assets":[{"name":"SHA256SUMS"},{"name":"`, bundle, `"}]}]`}, context.temp_allocator)
		return doc, true, ""
	})
	defer delete(version)
	testing.expect_value(t, version, "v999.0.0")
}

@(test)
test_auto_update_quiet_admission :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	defer {
		sync.mutex_lock(&bridge_auto_update_mutex)
		bridge_auto_update_reserved_until = 0
		sync.mutex_unlock(&bridge_auto_update_mutex)
	}
	testing.expect(t, bridge_auto_update_launch_enter())
	testing.expect(t, !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host), "a preparing launch prevents update admission")
	bridge_auto_update_launch_leave()
	if !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host) { testing.expect(t, false, "fixture unexpectedly has running launches"); return }
	testing.expect(t, bridge_auto_update_quiet_with_host(true, auto_update_test_empty_host))
	testing.expect(t, !bridge_auto_update_launch_enter(), "new agents cannot race the detached updater")
	launched, _, err := bridge_runtime_launch_agent("auto-update-test", `{"agent_instance_id":"auto-update-test"}`)
	testing.expect(t, !launched)
	testing.expect_value(t, err.class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, err.retry_after_ms, i64(30_000))
}

auto_update_test_empty_host :: proc(socket: string) -> (Pty_Host_Reply, bool) {
	return {kind = .Agent_List}, true
}

@(test)
test_auto_update_quiet_preserved_pty_agent :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// No current-process launch exists, as after a bridge restart.
	sync.mutex_lock(&bridge_runtime_mutex)
	count := len(bridge_runtime_launches)
	sync.mutex_unlock(&bridge_runtime_mutex)
	testing.expect_value(t, count, 0)
	testing.expect(t, !bridge_auto_update_quiet_with_host(true, proc(socket: string) -> (Pty_Host_Reply, bool) {
		reply := Pty_Host_Reply{kind = .Agent_List}
		reply.agents = make([]Pty_Host_Agent_Info, 1)
		reply.agents[0] = {instance_id = strings.clone("preserved-agent"), alive = true}
		return reply, true
	}), "a preserved PTY agent prevents update admission")
	testing.expect(t, !bridge_auto_update_quiet_with_host(true, proc(socket: string) -> (Pty_Host_Reply, bool) {
		return {}, false
	}), "failed PTY listing prevents update admission")
	testing.expect(t, bridge_auto_update_launch_enter(), "busy or unavailable host must not reserve admission")
	bridge_auto_update_launch_leave()
}
