package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_provider_extension_install_progress_json_format :: proc(t: ^testing.T) {
	frame_installing := bridge_provider_extension_install_progress_json(
		"cmd_test_1",
		"antigravity",
		"installing",
		25,
		"Downloading assets",
	)
	defer delete(frame_installing)

	testing.expect(t, strings.contains(frame_installing, `"type":"provider_extension_install_progress"`), "type is provider_extension_install_progress")
	testing.expect(t, strings.contains(frame_installing, `"command_id":"cmd_test_1"`), "command_id is correct")
	testing.expect(t, strings.contains(frame_installing, `"provider":"antigravity"`), "provider is correct")
	testing.expect(t, strings.contains(frame_installing, `"stage":"installing"`), "stage is installing")
	testing.expect(t, strings.contains(frame_installing, `"progress_percent":25`), "progress_percent is 25")
	testing.expect(t, strings.contains(frame_installing, `"message":"Downloading assets"`), "message is correct")
	testing.expect(t, !strings.contains(frame_installing, `"error"`), "installing stage does not have error")

	frame_succeeded := bridge_provider_extension_install_progress_json(
		"cmd_test_2",
		"antigravity",
		"succeeded",
		100,
		"Installed",
	)
	defer delete(frame_succeeded)
	testing.expect(t, strings.contains(frame_succeeded, `"stage":"succeeded"`), "stage is succeeded")
	testing.expect(t, strings.contains(frame_succeeded, `"progress_percent":100`), "progress_percent is 100")

	frame_failed := bridge_provider_extension_install_progress_json(
		"cmd_test_3",
		"antigravity",
		"failed",
		0,
		"Binary missing",
	)
	defer delete(frame_failed)
	testing.expect(t, strings.contains(frame_failed, `"stage":"failed"`), "stage is failed")
	testing.expect(t, strings.contains(frame_failed, `"error"`), "failed stage includes error object")
	testing.expect(t, strings.contains(frame_failed, `"Binary missing"`), "error message is preserved")
}

@(test)
test_provider_extension_build_install_args :: proc(t: ^testing.T) {
	// 1. Antigravity
	agy_args := bridge_provider_extension_build_install_args("antigravity", "/bin/agy", "/path/to/extensions/antigravity", context.allocator)
	defer delete(agy_args)
	testing.expect_value(t, len(agy_args), 4)
	if len(agy_args) == 4 {
		testing.expect_value(t, agy_args[0], "/bin/agy")
		testing.expect_value(t, agy_args[1], "plugin")
		testing.expect_value(t, agy_args[2], "install")
		testing.expect_value(t, agy_args[3], "/path/to/extensions/antigravity")
	}

	// 2. Claude installs by plugin id from a registered marketplace; older
	// Claude Code releases reject `--marketplace` and `-y`.
	claude_args := bridge_provider_extension_build_install_args("claude", "/bin/claude", "/path/to/extensions/claude-code", context.allocator)
	defer delete(claude_args)
	testing.expect_value(t, len(claude_args), 4)
	if len(claude_args) == 4 {
		testing.expect_value(t, claude_args[0], "/bin/claude")
		testing.expect_value(t, claude_args[1], "plugin")
		testing.expect_value(t, claude_args[2], "install")
		testing.expect_value(t, claude_args[3], "heimdall@heimdall")
	}
	for arg in claude_args do testing.expectf(t, arg != "--marketplace" && arg != "-y", "unsupported Claude flag %q", arg)

	// 3. Codex
	codex_args := bridge_provider_extension_build_install_args("codex", "/bin/codex", "/path/to/extensions/codex", context.allocator)
	defer delete(codex_args)
	testing.expect_value(t, len(codex_args), 4)
	if len(codex_args) == 4 {
		testing.expect_value(t, codex_args[0], "/bin/codex")
		testing.expect_value(t, codex_args[1], "plugin")
		testing.expect_value(t, codex_args[2], "add")
		testing.expect_value(t, codex_args[3], "heimdall@heimdall-codex")
	}
}

test_install_mu: sync.Mutex
test_install_calls: [dynamic][]string
test_install_list_count: int
// Every installer call whose verb (argv[2], or argv[3] after "marketplace") is
// in this set fails; "" disables. Unlike a step index this survives retries.
test_install_fail_verbs: []string
test_install_already: bool
// The first `marketplace add` fails as codex does when another source holds the name.
test_install_add_conflict_once: bool
test_install_probe_state: string
test_install_probe_version: string
test_install_probe_count: int
// The discovery before any installer step sees the pre-install registration.
test_install_pre_state: string
test_install_pre_version: string
// `plugin marketplace list --json` output ("" = not JSON).
test_install_marketplaces: string
test_install_command_id: string
test_install_required: string
test_install_bundle: string
test_install_test: ^testing.T

test_install_verb :: proc(args: []string) -> string {
	if len(args) > 3 && args[2] == "marketplace" do return fmt.tprintf("marketplace %s", args[3])
	return args[2] if len(args) > 2 else ""
}

test_install_runner :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	testing.expect(test_install_test, timeout > 0 && timeout <= 25 * time.Second)
	verb := test_install_verb(args)
	if verb == "marketplace list" {
		test_install_list_count += 1
		return strings.clone(test_install_marketplaces), strings.clone(""), 0, true, false
	}
	copied := make([]string, len(args), context.temp_allocator)
	for arg, i in args do copied[i] = strings.clone(arg, context.temp_allocator)
	append(&test_install_calls, copied)
	if test_install_add_conflict_once && verb == "marketplace add" {
		test_install_add_conflict_once = false
		return strings.clone(""), strings.clone("Error: marketplace 'heimdall-codex' is already added from a different source; remove it before adding this source"), 1, false, false
	}
	for v in test_install_fail_verbs {
		if v == verb do return strings.clone(""), strings.clone("Mock installation error"), 1, false, false
	}
	if test_install_already && verb == "install" {
		return strings.clone("ALREADY INSTALLED"), strings.clone(""), 0, true, false
	}
	return strings.clone("Installed"), strings.clone(""), 0, true, false
}

test_install_discover :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path {
	test_install_probe_count += 1
	cached, _ := bridge_runtime_cached_command(test_install_command_id)
	testing.expect(test_install_test, !strings.contains(cached, `"status":"succeeded"`), "success must not be cached before verification")
	pre_install := test_install_probe_count == 1
	results := make([dynamic]Bridge_Provider_Path)
	append(&results, Bridge_Provider_Path{
		provider = strings.clone(filter[0]),
		state = strings.clone("present"),
		extension_state = strings.clone(test_install_pre_state if pre_install else test_install_probe_state),
		extension_version = strings.clone(test_install_pre_version if pre_install else test_install_probe_version),
	})
	return results
}

test_install_bundle_resolver :: proc(provider: string, allocator := context.allocator) -> string {
	return strings.clone(test_install_bundle, allocator)
}

test_install_binary_resolver :: proc(provider: string) -> (string, bool) {
	return strings.clone("/fake/provider"), true
}

test_install_fixture :: proc(t: ^testing.T) -> string {
	root := fmt.tprintf("%s/test-install-%p-%d", bridge_scratch_root(context.temp_allocator), t, time.to_unix_nanoseconds(time.now()))
	for dir in ([]string{"", "codex", "codex/.codex-plugin", "antigravity", "claude-code", "claude-code/.claude-plugin", ".agents/plugins", ".claude-plugin"}) {
		testing.expect(t, bridge_make_directory_all(test_install_path({root, dir})) == nil)
	}
	for file in ([]string{"codex/.codex-plugin/plugin.json", "claude-code/.claude-plugin/plugin.json", "antigravity/plugin.json"}) {
		testing.expect(t, os.write_entire_file_from_string(test_install_path({root, file}), `{"version":"0.4.31"}`) == nil)
	}
	for file in ([]string{".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"}) {
		testing.expect(t, os.write_entire_file_from_string(test_install_path({root, file}), "{}") == nil)
	}
	return root
}

test_install_reset :: proc(t: ^testing.T, name: string) {
	test_install_test = t
	test_install_command_id = fmt.tprintf("install-%s-%p-%d", name, t, time.to_unix_nanoseconds(time.now()))
	test_install_calls = make([dynamic][]string, context.temp_allocator)
	test_install_list_count = 0
	test_install_fail_verbs = nil
	test_install_already = false
	test_install_add_conflict_once = false
	test_install_probe_state = "present"
	test_install_probe_version = "0.4.31"
	test_install_probe_count = 0
	test_install_pre_state = "absent"
	test_install_pre_version = ""
	test_install_marketplaces = "[]"
	test_install_required = ""
}

test_install_required_version :: proc(provider: string) -> string {
	return test_install_required
}

// Swaps every hook the install path uses; call restore when done.
Test_Install_Hooks :: struct {
	runner:   Bridge_Extension_Install_Runner,
	discover: Bridge_Provider_Discover_Proc,
	required: Bridge_Extension_Required_Version_Proc,
	bundle:   Bridge_Extension_Bundle_Resolver,
	binary:   Bridge_Extension_Binary_Resolver,
	others:   Bridge_Extension_Other_Profiles,
	own_ensure: Bridge_Codex_Own_Ensure,
	own_remove: Bridge_Codex_Own_Remove,
	own_heal:   Bridge_Codex_Own_Heal,
}

// The machine running the tests may have real bridge profiles installed.
test_install_no_other_profiles :: proc() -> int {return test_install_other_profiles}
test_install_other_profiles := 0

test_install_hook :: proc() -> Test_Install_Hooks {
	saved := Test_Install_Hooks{bridge_extension_install_runner, bridge_extension_discover, bridge_extension_required_version,
		bridge_extension_bundle_resolver, bridge_extension_binary_resolver, bridge_extension_other_profiles,
		bridge_codex_own_ensure_hook, bridge_codex_own_remove_hook, bridge_codex_own_heal_hook}
	bridge_codex_own_ensure_hook = proc(bin_path: string, deadline: time.Time, env: []string) -> (bool, string) { return false, "disabled in tests" }
	bridge_codex_own_remove_hook = proc(bin_path: string, deadline: time.Time, env: []string) {}
	bridge_codex_own_heal_hook = proc() -> (int, string) { return 0, "" }
	test_install_other_profiles = 0
	bridge_extension_other_profiles = test_install_no_other_profiles
	bridge_extension_install_runner = test_install_runner
	bridge_extension_discover = test_install_discover
	bridge_extension_required_version = test_install_required_version
	bridge_extension_bundle_resolver = test_install_bundle_resolver
	bridge_extension_binary_resolver = test_install_binary_resolver
	return saved
}

test_install_restore :: proc(saved: Test_Install_Hooks) {
	bridge_extension_install_runner = saved.runner
	bridge_extension_discover = saved.discover
	bridge_extension_required_version = saved.required
	bridge_extension_bundle_resolver = saved.bundle
	bridge_extension_binary_resolver = saved.binary
	bridge_extension_other_profiles = saved.others
	bridge_codex_own_ensure_hook = saved.own_ensure
	bridge_codex_own_remove_hook = saved.own_remove
	bridge_codex_own_heal_hook = saved.own_heal
}

// Claude Code before 2.1.295 rejects `--marketplace`, and releases such as
// 2.1.119 reject `-y` on install and update.
test_install_expect_supported_flags :: proc(t: ^testing.T, provider: string) {
	for call in test_install_calls {
		for arg in call {
			testing.expectf(t, arg != "--marketplace" && arg != "-y" && arg != "--yes", "%s: unsupported installer flag %q in %v", provider, arg, call)
		}
	}
}

test_install_verbs :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for call, i in test_install_calls {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, test_install_verb(call))
	}
	return strings.to_string(b)
}

// The frame names only the provider that is honoured; the bundle comes from
// test_install_bundle via the local resolver.
test_install_run :: proc(provider, path: string) -> string {
	test_install_bundle = path
	payload := fmt.tprintf(`{{"type":"provider_extension_install","command_id":"%s","provider":"%s"}}`, test_install_command_id, provider)
	bridge_hub_handle_extension_install_command(nil, payload)
	result, ok := bridge_runtime_cached_command(test_install_command_id)
	testing.expect(test_install_test, ok)
	return strings.clone(result)
}

@(test)
test_bridge_extension_install_provider_steps :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	for provider in ([]string{"antigravity", "claude", "claude-code", "codex"}) {
		test_install_reset(t, provider)
		variant := "claude-code" if provider == "claude" else provider
		result := test_install_run(provider, test_install_path({root, variant}))
		testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s: %s", provider, result)
		delete(result)
		testing.expect_value(t, test_install_probe_count, 2)
		test_install_expect_supported_flags(t, provider)
		if provider == "codex" {
			testing.expect_value(t, test_install_verbs(), "marketplace add,add")
			if len(test_install_calls) == 2 do testing.expect_value(t, test_install_calls[0][4], root)
		} else if provider == "antigravity" {
			testing.expect_value(t, test_install_verbs(), "install")
		} else {
			testing.expectf(t, test_install_verbs() == "marketplace add,install", "%s: %s", provider, test_install_verbs())
			if len(test_install_calls) == 2 {
				testing.expect_value(t, test_install_calls[0][4], root)
				testing.expect_value(t, test_install_calls[1][3], "heimdall@heimdall")
			}
		}
	}
}

// F12: a Hub frame naming a binary or extension path never gets it executed.
@(test)
test_bridge_extension_install_ignores_hub_supplied_paths :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	for provider in ([]string{"antigravity", "claude", "codex"}) {
		test_install_reset(t, fmt.tprintf("hub-paths-%s", provider))
		variant := "claude-code" if provider == "claude" else provider
		test_install_bundle = test_install_path({root, variant})
		payload := fmt.tprintf(`{{"type":"provider_extension_install","command_id":"%s","provider":"%s","binary_path":"/evil/bin/sh","extension_path":"/evil/ext"}}`,
			test_install_command_id, provider)
		bridge_hub_handle_extension_install_command(nil, payload)
		result, _ := bridge_runtime_cached_command(test_install_command_id)
		testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s: %s", provider, result)
		testing.expect(t, len(test_install_calls) > 0)
		for call in test_install_calls {
			testing.expectf(t, call[0] == "/fake/provider", "%s: executed %q", provider, call[0])
			for arg in call do testing.expectf(t, !strings.contains(arg, "/evil"), "%s: hub path reached argv %v", provider, call)
		}
	}
	// No local bundle: the hub-supplied extension_path is not a fallback.
	test_install_reset(t, "hub-paths-no-bundle")
	test_install_bundle = ""
	payload := fmt.tprintf(`{{"type":"provider_extension_install","command_id":"%s","provider":"antigravity","extension_path":"%s"}}`,
		test_install_command_id, test_install_path({root, "antigravity"}))
	bridge_hub_handle_extension_install_command(nil, payload)
	result, _ := bridge_runtime_cached_command(test_install_command_id)
	testing.expectf(t, strings.contains(result, "extension_not_found"), "%s", result)
	testing.expect_value(t, len(test_install_calls), 0)
}

@(test)
test_bridge_extension_install_rejects_unverified_results :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	for state in ([]string{"absent", "disabled", "outdated", "error", "unsupported", "present", "unknown-version"}) {
		test_install_reset(t, state)
		test_install_probe_state = "present" if state == "unknown-version" else state
		test_install_probe_version = "0.1.0" if state == "present" else "" if state == "unknown-version" else "0.4.31"
		result := test_install_run("antigravity", test_install_path({root, "antigravity"}))
		testing.expect(t, strings.contains(result, `"status":"failed"`))
		testing.expect(t, strings.contains(result, "verify_failed"))
		delete(result)
		// Self-heal: one clean reinstall (uninstall + install) before reporting.
		testing.expectf(t, test_install_verbs() == "install,uninstall,install", "%s: %s", state, test_install_verbs())
		testing.expect_value(t, test_install_probe_count, 3)
	}
}

@(test)
test_bridge_extension_install_claude_update_and_errors :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	// "already installed" is followed by an update.
	test_install_reset(t, "claude-update")
	test_install_already = true
	result := test_install_run("claude", test_install_path({root, "claude-code"}))
	testing.expect(t, strings.contains(result, `"status":"succeeded"`))
	testing.expect_value(t, test_install_verbs(), "marketplace add,install,update")
	if len(test_install_calls) == 3 do testing.expect_value(t, test_install_calls[2][3], "heimdall@heimdall")
	delete(result)
	// A step that keeps failing is retried once after cleanup, then reported.
	Case :: struct { verb, code, verbs: string }
	for c in ([]Case{
		{"marketplace add", "marketplace_add_failed", "marketplace add,uninstall,marketplace remove,marketplace add"},
		{"install", "install_failed", "marketplace add,install,uninstall,marketplace remove,marketplace add,install"},
		{"update", "update_failed", "marketplace add,install,update,uninstall,marketplace remove,marketplace add,install,update"},
	}) {
		test_install_reset(t, c.verb)
		test_install_already = true
		test_install_fail_verbs = []string{c.verb}
		result = test_install_run("claude", test_install_path({root, "claude-code"}))
		testing.expectf(t, strings.contains(result, "Mock installation error") && strings.contains(result, c.code), "%s: %s", c.verb, result)
		testing.expectf(t, test_install_verbs() == c.verbs, "%s: %s", c.verb, test_install_verbs())
		testing.expect_value(t, test_install_probe_count, 1)
		test_install_expect_supported_flags(t, "claude")
		delete(result)
	}
	// Claude without marketplace metadata fails before running the provider.
	_ = os.remove(test_install_path({root, ".claude-plugin/marketplace.json"}))
	test_install_reset(t, "claude-missing-marketplace")
	missing := test_install_run("claude", test_install_path({root, "claude-code"}))
	testing.expect(t, strings.contains(missing, "missing_marketplace"))
	testing.expect_value(t, len(test_install_calls), 0)
	delete(missing)
}

@(test)
test_bridge_extension_install_custom_marketplace_and_invalid_input :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	test_install_reset(t, "codex-root")
	result := test_install_run("codex", root)
	testing.expect(t, strings.contains(result, `"status":"succeeded"`))
	delete(result)
	if len(test_install_calls) > 0 do testing.expect_value(t, test_install_calls[0][4], root)
	_ = os.remove(test_install_path({root, ".agents/plugins/marketplace.json"}))
	test_install_reset(t, "missing-marketplace")
	result = test_install_run("codex", root)
	testing.expect(t, strings.contains(result, "missing_marketplace"))
	testing.expect_value(t, len(test_install_calls), 0)
	delete(result)
	for provider in ([]string{"", "unsupported"}) {
		test_install_reset(t, "invalid")
		result = test_install_run(provider, root)
		testing.expect(t, strings.contains(result, `"status":"failed"`))
		testing.expect_value(t, len(test_install_calls), 0)
		delete(result)
	}
	test_install_reset(t, "expired")
	_, _, ok := bridge_extension_install_step({"/fake/provider"}, time.time_add(time.now(), -time.Second))
	testing.expect(t, !ok)
	testing.expect_value(t, len(test_install_calls), 0)
}

@(test)
test_bridge_extension_install_never_downgrades_registration :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	// The fixture bundles 0.4.31; this or another Bridge registered pre_version.
	Case :: struct { pre_version: string, skips: bool }
	cases := []Case{
		{"0.4.31", true}, {"v0.4.31", true}, {"0.4.32", true}, {"0.10.0", true}, {"1.0.0", true},
		{"0.4.30", false}, {"0.4.9", false}, {"0.3.99", false},
	}
	for provider in ([]string{"antigravity", "claude", "claude-code", "codex"}) {
		variant := "claude-code" if provider == "claude" else provider
		for c in cases {
			test_install_reset(t, fmt.tprintf("%s-%s", provider, c.pre_version))
			test_install_pre_state = "present"
			test_install_pre_version = c.pre_version
			result := test_install_run(provider, test_install_path({root, variant}))
			testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s %s: %s", provider, c.pre_version, result)
			delete(result)
			if c.skips {
				testing.expectf(t, len(test_install_calls) == 0, "%s %s: registration re-pointed by %d installer calls", provider, c.pre_version, len(test_install_calls))
				testing.expect_value(t, test_install_probe_count, 1)
				continue
			}
			// Outdated: removed, then added again from the bundle.
			testing.expect_value(t, test_install_probe_count, 2)
			want := "uninstall,install"
			if provider == "codex" do want = "remove,marketplace remove,marketplace add,add"
			else if provider != "antigravity" do want = "uninstall,marketplace remove,marketplace add,install"
			testing.expectf(t, test_install_verbs() == want, "%s %s: %s", provider, c.pre_version, test_install_verbs())
		}
	}
}

// REQ-EXTFIX-2: the bundled manifest, the catalog minimum and the installed
// version must agree. A bundle older than the minimum never runs an installer,
// and verification names the version Heimdall actually requires.
@(test)
test_bridge_extension_install_aligns_bundled_and_required_versions :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)

	// The screenshot case: installed and bundled 0.4.31, catalog requires 0.4.32.
	for provider in ([]string{"antigravity", "claude", "codex"}) {
		variant := "claude-code" if provider == "claude" else provider
		test_install_reset(t, fmt.tprintf("stale-%s", provider))
		test_install_required = "0.4.32"
		test_install_pre_state = "outdated"
		test_install_pre_version = "0.4.31"
		result := test_install_run(provider, test_install_path({root, variant}))
		testing.expectf(t, strings.contains(result, "bundled_extension_outdated"), "%s: %s", provider, result)
		testing.expectf(t, strings.contains(result, `requires \"0.4.32\" or newer`) && strings.contains(result, `version \"0.4.31\"`), "%s: diagnostic must name bundled and required versions: %s", provider, result)
		testing.expectf(t, strings.contains(result, test_install_path({root, variant})), "%s: diagnostic must name the stale bundle path: %s", provider, result)
		delete(result)
		testing.expectf(t, len(test_install_calls) == 0, "%s: stale bundle must not run installers, got %d calls", provider, len(test_install_calls))
		testing.expect_value(t, test_install_probe_count, 1)
	}

	// A current registration is still left alone even when this Bridge's
	// bundle is stale (no-downgrade guard runs first).
	test_install_reset(t, "stale-bundle-current-registration")
	test_install_required = "0.4.32"
	test_install_pre_state = "present"
	test_install_pre_version = "0.4.32"
	result := test_install_run("codex", test_install_path({root, "codex"}))
	testing.expect(t, strings.contains(result, `"status":"succeeded"`))
	testing.expect_value(t, len(test_install_calls), 0)
	delete(result)

	// An older catalog minimum keeps the bundled manifest as the target.
	test_install_reset(t, "older-minimum")
	test_install_required = "0.4.0"
	test_install_probe_state = "present"
	test_install_probe_version = "0.4.30"
	result = test_install_run("codex", test_install_path({root, "codex"}))
	testing.expect(t, strings.contains(result, "verify_failed"))
	testing.expectf(t, strings.contains(result, `(required \"0.4.31\" or newer, bundled \"0.4.31\")`), "verification must name the true target: %s", result)
	delete(result)

	// The catalog minimum equal to the bundle: an installer that leaves the
	// provider outdated names the required version, not a stale expectation.
	test_install_reset(t, "verify-outdated")
	test_install_required = "0.4.31"
	test_install_probe_state = "outdated"
	test_install_probe_version = "0.4.30"
	result = test_install_run("codex", test_install_path({root, "codex"}))
	testing.expect(t, strings.contains(result, "verify_failed"))
	testing.expectf(t, strings.contains(result, `version is \"0.4.30\" (required \"0.4.31\" or newer`), "verification diagnostic: %s", result)
	delete(result)

	// Aligned bundle and minimum installs and verifies.
	test_install_reset(t, "aligned")
	test_install_required = "0.4.31"
	result = test_install_run("codex", test_install_path({root, "codex"}))
	testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "aligned: %s", result)
	testing.expect_value(t, len(test_install_calls), 2)
	delete(result)
}

test_install_path :: proc(parts: []string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}
