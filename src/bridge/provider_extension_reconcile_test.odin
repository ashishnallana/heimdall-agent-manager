package main

import "core:fmt"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"
import "core:os"
import "core:strings"
import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_bridge_extension_classify :: proc(t: ^testing.T) {
	ours := "/home/u/.local/share/heimdall/bridges/heimdall-bridge/extensions"
	other := "/home/u/.local/share/heimdall/bridges/heimdall-bridge-b/extensions"
	Case :: struct { state, version: string, registered: bool, mp: string, want: Bridge_Extension_Condition }
	for c in ([]Case{
		{"present", "0.4.31", true, ours, .Current},
		{"present", "0.5.0", false, "", .Current},
		{"absent", "", false, "", .Absent},
		{"absent", "", true, ours, .Broken},       // marketplace without plugin
		{"outdated", "0.4.1", true, ours, .Outdated},
		{"present", "0.4.1", true, ours, .Outdated},
		{"disabled", "0.4.31", true, ours, .Broken},
		{"present", "", true, ours, .Broken},       // unknown version
		{"present", "0.4.31", true, "/home/u/src/heimdall/extensions", .Foreign},
		{"outdated", "0.4.1", true, other, .Foreign}, // another bridge's stale copy
		{"present", "0.4.31", true, other, .Other_Bridge},
	}) {
		got := bridge_extension_classify(c.state, c.version, "0.4.31", c.registered, c.mp, ours)
		testing.expectf(t, got == c.want, "%v: got %v", c, got)
	}
}

// Every profile of an OS user registers from the shared root; a registration
// from a profile's own copy or an older shared release moves there, a strictly
// newer Ninjy bundle is left alone (newest wins).
@(test)
test_bridge_extension_classify_shared_root :: proc(t: ^testing.T) {
	ours := "/home/u/.local/share/heimdall/bridges/.shared-extensions/0.5.30/extensions"
	older := "/home/u/.local/share/heimdall/bridges/.shared-extensions/0.5.29/extensions"
	profile := "/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub_work/extensions"
	Case :: struct { version, mp: string, want: Bridge_Extension_Condition }
	for c in ([]Case{
		{"0.4.31", ours, .Current},
		{"0.4.31", older, .Ninjy_Bundle},
		{"0.4.31", profile, .Ninjy_Bundle},
		{"0.4.32", profile, .Other_Bridge},
		{"0.4.32", older, .Other_Bridge},
		{"0.4.31", "/home/u/src/heimdall/extensions", .Foreign},
	}) {
		got := bridge_extension_classify("present", c.version, "0.4.31", true, c.mp, ours)
		testing.expectf(t, got == c.want, "%v: got %v", c, got)
	}
	testing.expect(t, bridge_extension_is_shared_bundle(ours))
	testing.expect(t, bridge_extension_is_bridge_bundle(ours), "bridges older than the shared root must leave it alone")
	testing.expect(t, !bridge_extension_is_shared_bundle(profile))
}

// Two profiles publish to one shared root: a release is published once, the
// newest release wins whichever profile installs last, and pruning keeps it.
@(test)
test_bridge_extensions_shared_root_publish :: proc(t: ^testing.T) {
	base := test_install_path({os.get_env("TMPDIR", context.temp_allocator) if os.get_env("TMPDIR", context.temp_allocator) != "" else "/tmp",
		fmt.tprintf("ham-shared-ext-%d", time.to_unix_nanoseconds(time.now()))})
	defer _ = os.remove_all(base)
	data_root := test_install_path({base, "heimdall", "bridges"})
	a := test_install_path({data_root, "heimdall-bridge-hub"})
	b := test_install_path({data_root, "heimdall-bridge-hub_work"})
	for d in ([]string{a, b}) {
		testing.expect(t, os.make_directory_all(test_install_path({d, "extensions", "claude-code"})) == nil)
		testing.expect(t, os.write_entire_file(test_install_path({d, "extensions", "claude-code", "marker"}), transmute([]u8)d) == nil)
	}
	root := bridge_extensions_shared_root(a)
	testing.expect_value(t, root, bridge_extensions_shared_root(b))
	testing.expect_value(t, root, test_install_path({data_root, BRIDGE_SHARED_EXTENSIONS_DIR}))

	shared, ok, msg := bridge_extensions_publish_shared(test_install_path({a, "extensions"}), a)
	testing.expectf(t, ok, "publish a: %s", msg)
	this := test_install_path({root, contracts.APP_VERSION, "extensions"})
	testing.expect_value(t, shared, this)
	// Profile b of the same release reuses a's published copy.
	shared, ok, _ = bridge_extensions_publish_shared(test_install_path({b, "extensions"}), b)
	testing.expect(t, ok)
	testing.expect_value(t, shared, this)
	marker, _ := os.read_entire_file(test_install_path({this, "claude-code", "marker"}), context.temp_allocator)
	testing.expect_value(t, string(marker), a)

	// A newer release published by another profile wins over ours.
	newer := test_install_path({root, "999.0.0", "extensions"})
	testing.expect(t, os.make_directory_all(newer) == nil)
	shared, ok, _ = bridge_extensions_publish_shared(test_install_path({a, "extensions"}), a)
	testing.expect_value(t, shared, newer)
	bridge_extensions_prune_shared(newer)
	testing.expect(t, os.is_dir(newer))
	testing.expect(t, !os.is_dir(this), "older shared release pruned once every provider uses the newest")
	// Uninstalling profile a (its whole data dir) leaves the shared root intact.
	_ = os.remove_all(a)
	testing.expect_value(t, bridge_extensions_newest_shared(root), newer)
}

// A per-account provider profile registers from its profile's own copy, so
// another profile publishing a newer shared release and pruning the older one
// leaves that registration's directory in place.
@(test)
test_bridge_extensions_profile_registration_survives_prune :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	base := test_install_path({os.get_env("TMPDIR", context.temp_allocator) if os.get_env("TMPDIR", context.temp_allocator) != "" else "/tmp",
		fmt.tprintf("ham-shared-ext-pp-%d-%d", os.get_pid(), time.to_unix_nanoseconds(time.now()))})
	defer _ = os.remove_all(base)
	data_root := test_install_path({base, "heimdall", "bridges"})
	a := test_install_path({data_root, "heimdall-bridge-hub"})
	testing.expect(t, os.make_directory_all(test_install_path({a, "extensions", "claude-code"})) == nil)
	saved_data := bridge_config.data_dir
	defer bridge_config.data_dir = saved_data
	bridge_config.data_dir = a

	// Release N is the newest shared release when the provider profile installs.
	shared, ok, msg := bridge_extensions_publish_shared(test_install_path({a, "extensions"}), a)
	testing.expectf(t, ok, "publish: %s", msg)
	got := bridge_get_profile_extension_path("claude", context.temp_allocator)
	testing.expect_value(t, got, test_install_path({a, "extensions", "claude-code"}))
	testing.expect(t, !strings.has_prefix(got, bridgesvc.pdir(shared)), "provider profile must not register from a shared release")

	// Another profile publishes N+1 and prunes N.
	newer := test_install_path({bridge_extensions_shared_root(a), "999.0.0", "extensions"})
	testing.expect(t, os.make_directory_all(newer) == nil)
	bridge_extensions_prune_shared(newer)
	testing.expect(t, !os.is_dir(shared), "release N pruned")
	testing.expect(t, os.is_dir(got), "provider-profile registration still resolves after prune")

	// Without its own copy a profile falls back to the general resolver.
	_ = os.remove_all(test_install_path({a, "extensions"}))
	testing.expect(t, !strings.has_prefix(bridge_get_profile_extension_path("claude", context.temp_allocator), a))
}

@(test)
test_bridge_extension_parse_marketplace :: proc(t: ^testing.T) {
	claude := `[{"name":"other","path":"/x"},{"name":"heimdall","source":"directory","path":"/src/ext"}]`
	path, registered, parsed := bridge_extension_parse_marketplace(claude, "heimdall")
	testing.expect(t, parsed && registered)
	testing.expect_value(t, path, "/src/ext")
	codex := `{"marketplaces":[{"name":"heimdall-codex","marketplaceSource":{"source":"/src/codex"}}]}`
	path, registered, parsed = bridge_extension_parse_marketplace(codex, "heimdall-codex")
	testing.expect(t, parsed && registered)
	testing.expect_value(t, path, "/src/codex")
	_, registered, parsed = bridge_extension_parse_marketplace(`[]`, "heimdall")
	testing.expect(t, parsed && !registered)
	_, _, parsed = bridge_extension_parse_marketplace("not json", "heimdall")
	testing.expect(t, !parsed)
}

// ENR-12: a registration from another source, an outdated one and a
// half-installed one are removed and added again from the bundle, per provider.
@(test)
test_bridge_extension_self_heals_per_provider :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)

	Scenario :: struct { name, pre_state, pre_version: string, other_source: bool, mp_registered: bool }
	scenarios := []Scenario{
		{"foreign-source", "present", "0.4.31", true, true},
		{"outdated", "outdated", "0.4.1", false, true},
		{"half-installed", "absent", "", false, true},
		{"broken", "error", "0.4.31", false, true},
	}
	for provider in ([]string{"claude", "codex", "antigravity"}) {
		variant := "claude-code" if provider == "claude" else provider
		mp_name := bridge_extension_marketplace_name(provider)
		for sc in scenarios {
			// Antigravity has no marketplace: a foreign source and a
			// half-installed marketplace cannot be observed there.
			if provider == "antigravity" && (sc.other_source || sc.name == "half-installed") do continue
			test_install_reset(t, fmt.tprintf("%s-%s", provider, sc.name))
			test_install_pre_state = sc.pre_state
			test_install_pre_version = sc.pre_version
			mp_path := "/home/u/checkout/extensions" if sc.other_source else root
			if mp_name != "" && sc.mp_registered {
				if provider == "codex" {
					test_install_marketplaces = fmt.tprintf(`{{"marketplaces":[{{"name":"%s","root":"%s"}}]}}`, mp_name, mp_path)
				} else {
					test_install_marketplaces = fmt.tprintf(`[{{"name":"%s","path":"%s"}}]`, mp_name, mp_path)
				}
			}
			result := test_install_run(provider, test_install_path({root, variant}))
			testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s %s: %s", provider, sc.name, result)
			delete(result)
			want := "uninstall,install"
			switch provider {
			case "claude": want = "uninstall,marketplace remove,marketplace add,install"
			case "codex":  want = "remove,marketplace remove,marketplace add,add"
			}
			testing.expectf(t, test_install_verbs() == want, "%s %s: %s", provider, sc.name, test_install_verbs())
			if mp_name != "" {
				testing.expect_value(t, test_install_list_count, 1)
				for call in test_install_calls {
					if test_install_verb(call) == "marketplace add" do testing.expectf(t, call[4] == root, "%s %s: re-added from %s", provider, sc.name, call[4])
				}
			}
		}
	}

	// Another Bridge's current bundle under the same OS user is left alone.
	for provider in ([]string{"claude", "codex"}) {
		test_install_reset(t, fmt.tprintf("%s-other-bridge", provider))
		test_install_pre_state = "present"
		test_install_pre_version = "0.4.31"
		test_install_marketplaces = fmt.tprintf(`[{{"name":"%s","path":"/home/u/.local/share/heimdall/bridges/b2/extensions"}}]`, bridge_extension_marketplace_name(provider))
		variant := "claude-code" if provider == "claude" else provider
		result := test_install_run(provider, test_install_path({root, variant}))
		testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s: %s", provider, result)
		testing.expectf(t, len(test_install_calls) == 0, "%s: other bridge re-pointed: %s", provider, test_install_verbs())
		delete(result)
	}
}

// The engine is usable without a Hub connection (setup / extensions sync).
@(test)
test_bridge_extension_ensure_reports_through_sink :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	test_install_reset(t, "sink")
	Capture :: struct { stages: [dynamic]string, reports: int }
	capture := Capture{stages = make([dynamic]string, context.temp_allocator)}
	sink := Bridge_Extension_Sink{
		data = &capture,
		progress = proc(data: rawptr, stage: string, pct: int, message: string) {
			c := (^Capture)(data)
			append(&c.stages, strings.clone(stage, context.temp_allocator))
		},
		report = proc(data: rawptr, results: []Bridge_Provider_Path) { (^Capture)(data).reports += 1 },
	}
	result := bridge_extension_ensure("codex", test_install_path({root, "codex"}), "/fake/provider", time.time_add(time.now(), 30 * time.Second), sink)
	testing.expectf(t, result.ok && result.action == "installed" && result.condition == .Absent, "%v", result)
	testing.expect_value(t, result.version, "0.4.31")
	testing.expect(t, len(capture.stages) > 0)
	testing.expect_value(t, capture.reports, 1)
}

test_sync_discover_present: [3]bool

// Pre-install state until the provider's own install step is the last call.
test_sync_discover :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path {
	results := make([dynamic]Bridge_Provider_Path)
	last := ""
	if n := len(test_install_calls); n > 0 && len(test_install_calls[n - 1]) > 3 do last = test_install_calls[n - 1][3]
	for p, i in BRIDGE_EXTENSION_PROVIDERS {
		present := test_sync_discover_present[i]
		installed := len(filter) == 1 && (last == BRIDGE_CLAUDE_PLUGIN_ID && p == "claude" || last == BRIDGE_CODEX_PLUGIN_ID && p == "codex")
		append(&results, Bridge_Provider_Path{
			provider = strings.clone(p),
			resolved_path = strings.clone("/fake/provider" if present else ""),
			state = strings.clone("present" if present else "absent"),
			extension_state = strings.clone(test_install_probe_state if installed else test_install_pre_state),
			extension_version = strings.clone(test_install_probe_version if installed else ""),
		})
	}
	return results
}

// Setup and update: the bundle is copied into <data dir>/extensions and every
// detected provider is ensured from that copy; undetected providers are skipped.
@(test)
test_bridge_extensions_sync_installs_bundle_for_detected_providers :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	bridge_extension_discover = test_sync_discover
	src := test_install_fixture(t)
	defer _ = os.remove_all(src)
	data_dir := fmt.tprintf("%s-data", src)
	defer _ = os.remove_all(data_dir)
	test_install_reset(t, "sync")
	test_install_pre_state = "absent"
	test_install_probe_version = "0.4.31"
	test_sync_discover_present = {true, true, false} // claude, codex; no antigravity

	ok, msg := bridge_extensions_install_bundle(src, data_dir)
	testing.expectf(t, ok, "%s", msg)
	ext_root := test_install_path({data_dir, "extensions"})
	testing.expect(t, os.exists(test_install_path({ext_root, "codex", ".codex-plugin", "plugin.json"})))
	testing.expect(t, os.exists(test_install_path({ext_root, ".claude-plugin", "marketplace.json"})))

	Seen :: struct { names: [dynamic]string }
	seen := Seen{names = make([dynamic]string, context.temp_allocator)}
	lines, failures := bridge_extensions_sync_providers(ext_root, proc(data: rawptr, line: Bridge_Extension_Sync_Line) {
		append(&(^Seen)(data).names, strings.clone(line.line, context.temp_allocator))
	}, &seen)
	testing.expect_value(t, failures, 0)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, len(seen.names), 3)
	if len(lines) == 3 {
		testing.expectf(t, lines[0].ok && !lines[0].skipped && strings.contains(lines[0].line, "installed"), "%v", lines[0])
		testing.expectf(t, lines[1].ok && !lines[1].skipped, "%v", lines[1])
		testing.expectf(t, lines[2].skipped, "%v", lines[2])
	}
	// Markets are registered from the data-dir copy, never the source bundle.
	for call in test_install_calls {
		if test_install_verb(call) == "marketplace add" do testing.expectf(t, bridge_extension_same_path(call[4], ext_root), "registered %s", call[4])
	}

	// A second install keeps the previous copy for rollback; restore puts it back.
	_ = os.write_entire_file_from_string(test_install_path({ext_root, "marker"}), "old")
	ok, msg = bridge_extensions_install_bundle(src, data_dir)
	testing.expectf(t, ok, "%s", msg)
	testing.expect(t, !os.exists(test_install_path({ext_root, "marker"})))
	bridge_extensions_restore(data_dir)
	testing.expect(t, os.exists(test_install_path({ext_root, "marker"})))
	// Installing the data-dir copy onto itself is a no-op.
	ok, msg = bridge_extensions_install_bundle(ext_root, data_dir)
	testing.expect(t, ok && msg == "skipped")
}

// A provider CLI shared by two concurrent ensures (update `extensions sync` and
// the Hub's reconnect follow-up install), simulated with real registration state.
Test_Race :: struct {
	mu:            sync.Mutex,
	installed:     string, // plugin version registered now ("" = none)
	mp_registered: bool,
	root:          string,
	verbs:         [dynamic]string, // heap: appended from two threads
	second:        ^thread.Thread,
	second_ok:     bool,
	second_action: string,
	second_cond:   Bridge_Extension_Condition,
	blocked_calls: int, // installer calls B made while A was installing (want 0)
}
test_race: Test_Race

test_race_second :: proc(_: rawptr) {
	r := bridge_extension_ensure("claude", test_install_path({test_race.root, "claude-code"}), "/fake/provider",
		time.time_add(time.now(), 30 * time.Second), {})
	sync.mutex_lock(&test_race.mu)
	defer sync.mutex_unlock(&test_race.mu)
	test_race.second_ok, test_race.second_cond = r.ok, r.condition
	test_race.second_action = strings.clone(r.action, runtime.heap_allocator())
}

test_race_runner :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	verb := test_install_verb(args)
	spawn := false
	before := 0
	{
		sync.mutex_lock(&test_race.mu)
		defer sync.mutex_unlock(&test_race.mu)
		if verb == "marketplace list" {
			if !test_race.mp_registered do return strings.clone("[]"), strings.clone(""), 0, true, false
			return fmt.aprintf(`[{{"name":"heimdall","path":"%s"}}]`, test_race.root), strings.clone(""), 0, true, false
		}
		append(&test_race.verbs, strings.clone(verb, runtime.heap_allocator()))
		switch verb {
		case "uninstall":          test_race.installed = ""
		case "marketplace remove": test_race.mp_registered = false
		case "marketplace add":    test_race.mp_registered = true
		case "install":            spawn = test_race.second == nil
		}
		before = len(test_race.verbs)
	}
	if spawn {
		// B starts while A is between install and verify: the window in which
		// B's cleanup used to remove A's fresh install.
		test_race.second = thread.create_and_start_with_data(nil, test_race_second)
		time.sleep(500 * time.Millisecond)
		sync.mutex_lock(&test_race.mu)
		test_race.blocked_calls = len(test_race.verbs) - before
		sync.mutex_unlock(&test_race.mu)
	}
	if verb == "install" {
		sync.mutex_lock(&test_race.mu)
		test_race.installed = "0.4.31"
		sync.mutex_unlock(&test_race.mu)
	}
	return strings.clone("Installed"), strings.clone(""), 0, true, false
}

test_race_discover :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path {
	sync.mutex_lock(&test_race.mu)
	defer sync.mutex_unlock(&test_race.mu)
	state := "absent"
	if test_race.installed != "" do state = "present" if test_race.installed == "0.4.31" else "outdated"
	results := make([dynamic]Bridge_Provider_Path)
	append(&results, Bridge_Provider_Path{
		provider = strings.clone(filter[0]),
		state = strings.clone("present"),
		extension_state = strings.clone(state),
		extension_version = strings.clone(test_race.installed),
	})
	return results
}

// Two ensures of one provider are serialized; the second re-classifies after
// taking the lock, finds the first one's install current and changes nothing.
@(test)
test_bridge_extension_concurrent_ensures_serialize :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	bridge_extension_install_runner = test_race_runner
	bridge_extension_discover = test_race_discover
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	test_install_reset(t, "race")
	test_race = {installed = "0.4.1", mp_registered = true, root = root, verbs = make([dynamic]string, runtime.heap_allocator())}
	defer {
		for v in test_race.verbs do delete(v, runtime.heap_allocator())
		delete(test_race.verbs)
		delete(test_race.second_action, runtime.heap_allocator())
		test_race = {}
	}

	a := bridge_extension_ensure("claude", test_install_path({root, "claude-code"}), "/fake/provider", time.time_add(time.now(), 30 * time.Second), {})
	testing.expectf(t, a.ok && a.condition == .Outdated && a.action == "reinstalled", "first: %v", a)
	testing.expect(t, test_race.second != nil, "second ensure never started")
	if test_race.second != nil {
		thread.join(test_race.second)
		thread.destroy(test_race.second)
	}
	testing.expect_value(t, test_race.blocked_calls, 0)
	testing.expectf(t, test_race.second_ok && test_race.second_cond == .Current && test_race.second_action == "current",
		"second: ok=%v cond=%v action=%q", test_race.second_ok, test_race.second_cond, test_race.second_action)
	testing.expect_value(t, strings.join(test_race.verbs[:], ",", context.temp_allocator), "uninstall,marketplace remove,marketplace add,install")
	testing.expect_value(t, test_race.installed, "0.4.31")
	testing.expect(t, test_race.mp_registered)
}

// Uninstall removes the plugin and its marketplace (failures of either are
// tolerated), then a fresh discovery must no longer find the extension.
@(test)
test_bridge_extension_remove_uninstalls_and_verifies :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	reports := 0
	sink := Bridge_Extension_Sink{data = &reports, report = proc(data: rawptr, results: []Bridge_Provider_Path) { (^int)(data)^ += 1 }}

	test_install_reset(t, "remove")
	test_install_pre_state = "absent" // what discovery sees after the uninstall
	test_install_fail_verbs = {"marketplace remove"}
	result := bridge_extension_remove("codex", "/fake/provider", time.time_add(time.now(), 30 * time.Second), sink)
	testing.expectf(t, result.ok && result.action == "uninstalled", "%v", result)
	testing.expect_value(t, len(test_install_calls), 2)
	if len(test_install_calls) == 2 {
		testing.expect_value(t, test_install_verb(test_install_calls[0]), "remove")
		testing.expect_value(t, test_install_calls[0][3], BRIDGE_CODEX_PLUGIN_ID)
		testing.expect_value(t, test_install_verb(test_install_calls[1]), "marketplace remove")
	}
	testing.expect_value(t, reports, 1)

	test_install_reset(t, "remove-claude")
	test_install_pre_state = "absent"
	result = bridge_extension_remove("claude-code", "/fake/provider", time.time_add(time.now(), 30 * time.Second), {})
	testing.expectf(t, result.ok, "%v", result)
	if len(test_install_calls) > 0 do testing.expect_value(t, test_install_verb(test_install_calls[0]), "uninstall")

	// Another Ninjy account's profile on this OS user still uses the shared
	// registration: nothing is removed. A per-account provider profile's own
	// config dir is not shared and is cleaned up.
	test_install_reset(t, "remove-other-profile")
	test_install_other_profiles = 1
	result = bridge_extension_remove("codex", "/fake/provider", time.time_add(time.now(), 30 * time.Second), {})
	testing.expectf(t, result.ok && result.action == "left", "%v", result)
	testing.expect_value(t, len(test_install_calls), 0)
	pp := Provider_Profile{}
	result = bridge_extension_remove("codex", "/fake/provider", time.time_add(time.now(), 30 * time.Second), {profile = &pp})
	testing.expectf(t, result.action != "left", "%v", result)
	test_install_other_profiles = 0

	// A marketplace that survives removal is named, not reported as success.
	test_install_reset(t, "remove-marketplace-stuck")
	test_install_pre_state = "absent"
	test_install_marketplaces = `{"marketplaces":[{"name":"heimdall-codex","root":"/old/source"}]}`
	result = bridge_extension_remove("codex", "/fake/provider", time.time_add(time.now(), 30 * time.Second), {})
	testing.expectf(t, !result.ok && result.code == "marketplace_remove_failed" && strings.contains(result.message, "/old/source"), "%v", result)

	// Still registered afterwards: the uninstall failed, and says so.
	test_install_reset(t, "remove-stuck")
	test_install_pre_state = "present"
	test_install_pre_version = "0.4.31"
	result = bridge_extension_remove("codex", "/fake/provider", time.time_add(time.now(), 30 * time.Second), {})
	testing.expectf(t, !result.ok && result.code == "uninstall_failed", "%v", result)
}

// codex refuses `marketplace add` while another source (an older Bridge's bundle)
// holds the name; the install replaces it within the same attempt.
@(test)
test_bridge_extension_replaces_marketplace_from_another_source :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	saved := test_install_hook()
	defer test_install_restore(saved)
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	test_install_reset(t, "mp-conflict")
	test_install_add_conflict_once = true
	result := bridge_extension_ensure("codex", test_install_path({root, "codex"}), "/fake/provider", time.time_add(time.now(), 30 * time.Second), {})
	testing.expectf(t, result.ok && result.action == "installed", "%v", result)
	verbs := make([dynamic]string, context.temp_allocator)
	for call in test_install_calls do append(&verbs, test_install_verb(call))
	// add (refused) -> remove -> add -> plugin add, with no cleanup pass first.
	testing.expectf(t, len(verbs) >= 4 && verbs[0] == "marketplace add" && verbs[1] == "marketplace remove" && verbs[2] == "marketplace add" && verbs[3] == "add", "%v", verbs)
}
