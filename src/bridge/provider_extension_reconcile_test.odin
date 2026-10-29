package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
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
