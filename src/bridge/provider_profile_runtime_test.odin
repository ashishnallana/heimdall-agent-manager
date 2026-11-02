package main

import "core:encoding/json"

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

P1c_Test_State :: struct {
	dir, data_dir, store_path:                   string,
	test_catalog:                                []string,
	catalog:                                     ^Bridge_Provider_Catalog_Snapshot,
	catalog_loaded, paths_loaded, models_loaded: bool,
	paths:                                       [dynamic]Bridge_Provider_Path,
	models:                                      [dynamic]Bridge_Provider_Models,
	models_last_key:                             string,
	models_last_completed:                       i64,
}

p1c_test_setup :: proc(t: ^testing.T) -> P1c_Test_State {
	sync.mutex_lock(&bridge_test_config_mutex)
	sync.mutex_lock(&g_profile_test_mu)
	dir := fmt.tprintf("/tmp/ham-p1c-%d-%d", os.get_pid(), time.time_to_unix_nano(time.now()))
	testing.expect(t, os.make_directory(dir, {.Read_User, .Write_User, .Execute_User}) == nil)
	st := P1c_Test_State {
		dir          = dir,
		data_dir     = bridge_config.data_dir,
		store_path   = g_profile_test_store_path,
		test_catalog = g_profile_test_catalog,
	}
	bridge_config.data_dir = profile_join(dir, "data")
	g_profile_test_store_path = profile_join(dir, "provider_profiles.json")
	names := make([]string, 5, context.temp_allocator)
	copy(names, []string{"claude", "codex", "pi", "copilot", "antigravity"})
	g_profile_test_catalog = names
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	st.catalog, st.catalog_loaded =
		bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded
	snap := new(Bridge_Provider_Catalog_Snapshot, runtime.default_allocator())
	snap.providers = make([]Bridge_Catalog_Provider, 2, runtime.default_allocator())
	snap.providers[0] = Bridge_Catalog_Provider {
		provider = "claude",
		binary   = "p1c-missing-cli",
		state    = "active",
	}
	snap.providers[1] = Bridge_Catalog_Provider {
		provider = "codex",
		binary   = "p1c-other-missing-cli",
		state    = "active",
	}
	snap.providers[0].models = make([]Bridge_Catalog_Model, 1, runtime.default_allocator())
	snap.providers[0].models[0] = {
		model_id = "seed",
		state    = "active",
	}
	bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded = snap, true
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	sync.rw_mutex_lock(&bridge_provider_paths_mutex)
	st.paths, st.paths_loaded = bridge_provider_paths, bridge_provider_paths_loaded
	bridge_provider_paths, bridge_provider_paths_loaded =
		make([dynamic]Bridge_Provider_Path, runtime.default_allocator()), true
	sync.rw_mutex_unlock(&bridge_provider_paths_mutex)
	sync.mutex_lock(&bridge_models_mu)
	st.models, st.models_loaded = bridge_models_cache, bridge_models_loaded
	st.models_last_key, st.models_last_completed =
		bridge_models_last_key, bridge_models_last_completed
	bridge_models_cache, bridge_models_loaded =
		make([dynamic]Bridge_Provider_Models, runtime.default_allocator()), true
	bridge_models_last_key, bridge_models_last_completed = "", 0
	sync.mutex_unlock(&bridge_models_mu)
	return st
}

p1c_test_teardown :: proc(st: P1c_Test_State) {
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	delete(bridge_provider_catalog_snapshot.providers[0].models, runtime.default_allocator())
	delete(bridge_provider_catalog_snapshot.providers, runtime.default_allocator())
	free(bridge_provider_catalog_snapshot, runtime.default_allocator())
	bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded =
		st.catalog, st.catalog_loaded
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	sync.rw_mutex_lock(&bridge_provider_paths_mutex)
	for &p in bridge_provider_paths do bridge_provider_path_destroy(&p, runtime.default_allocator())
	delete(bridge_provider_paths)
	bridge_provider_paths, bridge_provider_paths_loaded = st.paths, st.paths_loaded
	sync.rw_mutex_unlock(&bridge_provider_paths_mutex)
	sync.mutex_lock(&bridge_models_mu)
	for &m in bridge_models_cache do bridge_models_destroy(&m, runtime.default_allocator())
	delete(bridge_models_cache)
	delete(bridge_models_last_key, runtime.default_allocator())
	bridge_models_cache, bridge_models_loaded = st.models, st.models_loaded
	bridge_models_last_key, bridge_models_last_completed =
		st.models_last_key, st.models_last_completed
	sync.mutex_unlock(&bridge_models_mu)
	bridge_config.data_dir = st.data_dir
	g_profile_test_store_path, g_profile_test_catalog = st.store_path, st.test_catalog
	_ = os.remove_all(st.dir)
	sync.mutex_unlock(&g_profile_test_mu)
	sync.mutex_unlock(&bridge_test_config_mutex)
}

p1c_put :: proc(t: ^testing.T, path, body: string, executable := false) {
	parent := filepath.dir(path)
	if err := bridge_make_directory_all(parent); err != nil && !os.is_dir(parent) do testing.expect(t, false)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)
	if executable do testing.expect(t, os.chmod(path, {.Read_User, .Write_User, .Execute_User}) == nil)
}

p1c_profile :: proc(id, binary, cfg, marker: string) -> Provider_Profile {
	env := make([]Provider_Profile_Env, 2, context.temp_allocator)
	env[0] = {
		name  = "PROFILE_MARKER",
		value = marker,
	}
	env[1] = {
		name  = "CLAUDE_CONFIG_DIR",
		value = "/wrong",
	}
	return Provider_Profile {
		profile_id = id,
		provider = "claude",
		enabled = true,
		config = Provider_Profile_Config{binary_path = binary, config_dir = cfg},
		environment = env,
	}
}

@(test)
test_profile_codex_shadow_layout_and_private_auth :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return // runtime symlink privilege is platform-dependent
	st := p1c_test_setup(t); defer p1c_test_teardown(st)
	shared, shadow := profile_join(st.dir, "shared"), profile_join(st.dir, "shadow")
	p1c_put(t, profile_join(shared, "auth.json"), "shared-auth")
	p1c_put(t, profile_join(shared, "config.toml"), "shared-config")
	p1c_put(t, profile_join(shared, "models_cache.json"), "shared-models")
	p1c_put(t, profile_join(shared, "auth.lock"), "shared-lock")
	p1c_put(t, profile_join(shared, "log/old"), "private-log")
	p1c_put(t, profile_join(shared, "memories/old"), "private-memory")
	p1c_put(t, profile_join(shared, "tmp/old"), "private-tmp")
	p1c_put(t, profile_join(shared, ".DS_Store"), "metadata")
	p1c_put(t, profile_join(shadow, "auth.json"), "shadow-auth")
	testing.expect(
		t,
		os.symlink(profile_join(shared, "auth.lock"), profile_join(shadow, "auth.lock")) == nil,
	)
	testing.expect(
		t,
		os.symlink(
			profile_join(shared, "models_cache.json"),
			profile_join(shadow, "models_cache.json"),
		) ==
		nil,
	)
	p := Provider_Profile {
		provider = "codex",
		config = Provider_Profile_Config{home_path = shared, shadow_home_path = shadow},
	}
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.None)
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.None)
	for name in ([]string{"config.toml", "sessions", "skills", "plugins", "sqlite", "logs", "thread-writer-locks"}) {
		link, err := os.read_link(profile_join(shadow, name), context.temp_allocator)
		testing.expect(t, err == nil && link == profile_join(shared, name))
	}
	auth, _ := os.read_entire_file(profile_join(shadow, "auth.json"), context.temp_allocator)
	testing.expect_value(t, string(auth), "shadow-auth")
	for name in ([]string{"auth.lock", "models_cache.json", "log", "memories", "tmp", ".DS_Store"}) {
		_, err := os.lstat(profile_join(shadow, name), context.temp_allocator)
		testing.expect(t, err == .Not_Exist)
	}
	testing.expect(t, os.remove(profile_join(shadow, "auth.json")) == nil)
	testing.expect(
		t,
		os.symlink(profile_join(shared, "auth.json"), profile_join(shadow, "auth.json")) == nil,
	)
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.Shadow_Home_Invalid)
	source, _ := os.read_entire_file(profile_join(shared, "auth.json"), context.temp_allocator)
	testing.expect_value(t, string(source), "shared-auth")
}

@(test)
test_profile_codex_shadow_conflicts_preserve_files_and_active_locks :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	st := p1c_test_setup(t); defer p1c_test_teardown(st)
	shared, shadow := profile_join(st.dir, "shared"), profile_join(st.dir, "shadow")
	p1c_put(t, profile_join(shared, "config.toml"), "source")
	p1c_put(t, profile_join(shadow, "config.toml"), "do-not-overwrite")
	p := Provider_Profile {
		provider = "codex",
		config = Provider_Profile_Config{home_path = shared, shadow_home_path = shadow},
	}
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.Shadow_Home_Invalid)
	raw, _ := os.read_entire_file(profile_join(shadow, "config.toml"), context.temp_allocator)
	testing.expect_value(t, string(raw), "do-not-overwrite")
	_ = os.remove(profile_join(shadow, "config.toml"))
	// Replace a pre-existing sessions link if it points at a different source.
	_ = os.remove(profile_join(shadow, "sessions"))
	testing.expect(
		t,
		os.symlink(profile_join(st.dir, "wrong"), profile_join(shadow, "sessions")) == nil,
	)
	p1c_put(t, profile_join(shadow, "thread-writer-locks/active.lock"), "held")
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.None)
	testing.expect(t, os.exists(profile_join(shadow, "thread-writer-locks/active.lock")))
	_ = os.remove(profile_join(shadow, "thread-writer-locks/active.lock"))
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.None)
	link, err := os.read_link(profile_join(shadow, "thread-writer-locks"), context.temp_allocator)
	testing.expect(t, err == nil && link == profile_join(shared, "thread-writer-locks"))
	p.config.shadow_home_path = shared
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.Shadow_Home_Invalid)
	p.config.shadow_home_path = profile_join(shared, "nested")
	testing.expect_value(t, profile_prepare_runtime(&p), Profile_Error.Shadow_Home_Invalid)
}

@(test)
test_profile_discovery_models_and_disabled_isolation :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	st := p1c_test_setup(t); defer p1c_test_teardown(st)
	binary := profile_join(st.dir, "provider")
	p1c_put(
		t,
		binary,
		`#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_CONFIG_DIR/calls"
if [ "$1" = --version ]; then printf '%s %s\n' "$PROFILE_MARKER" "$CLAUDE_CONFIG_DIR"; exit 0; fi
IFS= read -r request
printf '{"type":"control_response","response":{"request_id":"models","subtype":"success","response":{"models":[{"value":"model-%s","displayName":"Profile model"}]}}}\n' "$PROFILE_MARKER"
while :; do sleep 1; done
`,
		true,
	)
	a := p1c_profile("claude_a", binary, profile_join(st.dir, "a"), "A")
	b := p1c_profile("claude_b", binary, profile_join(st.dir, "b"), "B")
	custom := make(
		[]string,
		2,
		context.temp_allocator,
	); custom[0], custom[1] = "custom-A", "model-A"
	a.config.custom_models = custom
	testing.expect_value(t, profile_upsert(&a, nil, 1), Profile_Error.None)
	testing.expect_value(t, profile_upsert(&b, nil, 1), Profile_Error.None)
	for p in ([]Provider_Profile{a, b}) {
		results := bridge_provider_discover({"claude"}, p.profile_id)
		if testing.expect_value(t, len(results), 1) {
			testing.expect_value(t, results[0].profile_id, p.profile_id)
			testing.expect_value(t, results[0].state, "present")
			testing.expect_value(t, results[0].resolved_path, binary)
			testing.expect_value(
				t,
				results[0].version_text,
				fmt.tprintf("%s %s", p.environment[0].value, p.config.config_dir),
			)
			report := bridge_provider_discovery_report_json(
				"request",
				results[:],
			); defer delete(report)
			testing.expect(t, strings.contains(report, p.profile_id))
		}
		bridge_provider_paths_destroy_all(&results)
	}
	by_id := bridge_provider_discover(nil, a.profile_id)
	testing.expect(t, len(by_id) == 1 && by_id[0].provider == "claude")
	bridge_provider_paths_destroy_all(&by_id)
	testing.expect_value(t, len(bridge_provider_paths), 2)
	for p in ([]Provider_Profile{a, b}) {
		values := bridge_models_refresh({"claude"}, profile_id = p.profile_id)
		if testing.expect_value(t, len(values), 1) {
			testing.expect_value(t, values[0].profile_id, p.profile_id)
			testing.expect_value(t, values[0].models_state, "success")
			expected := 2 if p.profile_id == a.profile_id else 1
			testing.expect_value(t, len(values[0].models), expected)
			if len(values[0].models) > 0 do testing.expect_value(t, values[0].models[0].model_id, fmt.tprintf("model-%s", p.environment[0].value))
		}
		for &v in values do bridge_models_destroy(&v)
		delete(values)
	}
	snapshot := bridge_models_get(
		"claude",
		profile_id = a.profile_id,
	); defer bridge_models_destroy(&snapshot)
	testing.expect_value(t, len(snapshot.models), 1) // settings custom entries never enter probe snapshots
	default_snapshot := bridge_models_get("claude"); defer bridge_models_destroy(&default_snapshot)
	testing.expect(t, !default_snapshot.has_snapshot)
	testing.expect(
		t,
		profile_has_model(&a, "claude", "model-A") && !profile_has_model(&b, "claude", "model-A"),
	)
	testing.expect(t, profile_has_model(&a, "claude", "custom-A"))
	default_models := bridge_models_clone(
		Bridge_Provider_Models {
			provider = "claude",
			has_snapshot = true,
			models = []Bridge_Discovered_Model {
				{model_id = "default-only", label = "Default only"},
			},
		},
	)
	bridge_models_save(default_models)
	bridge_models_destroy(&default_models)
	fresh := Provider_Profile {
		provider   = "claude",
		profile_id = "claude_fresh",
	}
	testing.expect(
		t,
		!profile_has_model(&fresh, "claude", "default-only") &&
		profile_has_model(&fresh, "claude", "seed"),
	)
	before, _ := os.read_entire_file(
		profile_join(a.config.config_dir, "calls"),
		context.temp_allocator,
	)
	a.enabled = false
	testing.expect_value(t, profile_upsert(&a, nil, 2), Profile_Error.None)
	disabled := bridge_provider_discover({"claude"}, a.profile_id)
	testing.expect(
		t,
		len(disabled) == 1 &&
		disabled[0].state == "disabled" &&
		disabled[0].profile_id == a.profile_id,
	)
	bridge_provider_paths_destroy_all(&disabled)
	disabled_models := bridge_models_refresh({"claude"}, profile_id = a.profile_id)
	testing.expect(t, len(disabled_models) == 1 && disabled_models[0].models_state == "disabled")
	for &v in disabled_models do bridge_models_destroy(&v)
	delete(disabled_models)
	bridge_hub_handle_extension_install_command(
		nil,
		`{"provider":"claude","profile_id":"claude_a"}`,
	)
	after, _ := os.read_entire_file(
		profile_join(a.config.config_dir, "calls"),
		context.temp_allocator,
	)
	testing.expect_value(t, string(after), string(before))
}

@(test)
test_profile_extension_detection_uses_child_config_only :: proc(t: ^testing.T) {
	st := p1c_test_setup(t); defer p1c_test_teardown(st)
	cfg := profile_join(st.dir, "gemini-profile")
	p1c_put(t, profile_join(cfg, "config.json"), `{"plugins":{"heimdall":{"enabled":false}}}`)
	p1c_put(t, profile_join(cfg, "plugins/heimdall/plugin.json"), `{"version":"2.0.0"}`)
	env := []string {
		strings.concatenate({"GEMINI_CONFIG_DIR=", cfg}, context.temp_allocator),
		"HOME=/unrelated-home",
	}
	ext := Bridge_Catalog_Extension {
		plugin_id          = "heimdall",
		detect_argv        = []string{"plugin", "list"},
		detect_collection  = "imports",
		detect_id_key      = "name",
		detect_version_key = "version",
		detect_enabled_key = "enabled",
		min_version        = "1.0.0",
	}
	state, version := bridge_provider_extension_evaluate(
		ext,
		`{"imports":[{"name":"heimdall","importedAt":"today"}]}`,
		true,
		env = env,
	)
	defer delete(version)
	testing.expect_value(t, state, "disabled")
	testing.expect_value(t, version, "2.0.0")
	for path in bridge_extension_gemini_paths(env, "heimdall", true) do testing.expect(t, strings.has_prefix(path, cfg))
}

@(test)
test_profile_extension_install_remove_stays_in_selected_dirs :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	st := p1c_test_setup(t); defer p1c_test_teardown(st)
	binary, bundle := profile_join(st.dir, "provider"), profile_join(st.dir, "bundle")
	p1c_put(t, profile_join(bundle, ".claude-plugin/plugin.json"), `{"version":"1.0.0"}`)
	p1c_put(t, profile_join(bundle, ".claude-plugin/marketplace.json"), `{"name":"heimdall"}`)
	p1c_put(
		t,
		binary,
		`#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$CLAUDE_CONFIG_DIR/calls"
if [ "$1" = --version ]; then echo 1.0.0; exit; fi
if [ "$1 $2" = 'plugin list' ]; then
  if [ -f "$CLAUDE_CONFIG_DIR/installed" ]; then
    printf '%s\n' '[{"id":"heimdall@heimdall","version":"1.0.0","enabled":true}]'
  else echo '[]'; fi
  exit
fi
if [ "$1 $2" = 'plugin marketplace' ]; then
  case "$3" in
    list) if [ -f "$CLAUDE_CONFIG_DIR/marketplace" ]; then
      printf '[{"name":"heimdall","path":"%s"}]\n' "$(cat "$CLAUDE_CONFIG_DIR/marketplace")"
      else echo '[]'; fi;;
    add) printf '%s\n' "$4" > "$CLAUDE_CONFIG_DIR/marketplace";;
    remove) rm -f "$CLAUDE_CONFIG_DIR/marketplace";;
  esac
  exit
fi
case "$2" in
  install|update) if [ "$PROFILE_MARKER" = FAIL ]; then printf "credential=%s\\n" "$PROFILE_TOKEN" >&2; exit 37; fi; printf '%s\n' "$PROFILE_MARKER" > "$CLAUDE_CONFIG_DIR/installed";;
  uninstall) rm -f "$CLAUDE_CONFIG_DIR/installed";;
  *) exit 21;;
esac
`,
		true,
	)
	ext := Bridge_Catalog_Extension {
		plugin_id          = BRIDGE_CLAUDE_PLUGIN_ID,
		detect_argv        = []string{"plugin", "list", "--json"},
		detect_version_key = "version",
		detect_enabled_key = "enabled",
		min_version        = "1.0.0",
	}
	bridge_provider_catalog_snapshot.providers[0].extension = ext
	a := p1c_profile("claude_a", binary, profile_join(st.dir, "a"), "A")
	b := p1c_profile("claude_b", binary, profile_join(st.dir, "b"), "B")
	testing.expect_value(t, profile_upsert(&a, nil, 1), Profile_Error.None)
	testing.expect_value(t, profile_upsert(&b, nil, 1), Profile_Error.None)
	for p in ([]Provider_Profile{a, b}) {
		pp := p
		env, ok := profile_child_env(&pp)
		testing.expect(t, ok)
		result := bridge_extension_ensure(
			"claude",
			bundle,
			binary,
			time.time_add(time.now(), 10 * time.Second),
			Bridge_Extension_Sink{profile = &pp, env = env},
		)
		testing.expectf(
			t,
			result.ok,
			"install %s failed: %s %s",
			pp.profile_id,
			result.code,
			result.message,
		)
		raw, err := os.read_entire_file(
			profile_join(p.config.config_dir, "installed"),
			context.temp_allocator,
		)
		testing.expect(t, err == nil && strings.trim_space(string(raw)) == p.environment[0].value)
	}
	aenv, _ := profile_child_env(&a)
	removed := bridge_extension_remove(
		"claude",
		binary,
		time.time_add(time.now(), 10 * time.Second),
		Bridge_Extension_Sink{profile = &a, env = aenv},
	)
	testing.expectf(t, removed.ok, "remove failed: %s %s", removed.code, removed.message)
	testing.expect(t, !os.exists(profile_join(a.config.config_dir, "installed")))
	testing.expect(t, os.exists(profile_join(b.config.config_dir, "installed")))
	// An installer error is sent through the real handler; secret env values
	// must not reach its cached client response even when the CLI echoes them.
	secret_env := make([]Provider_Profile_Env, 2, context.temp_allocator)
	secret_env[0] = {
		name  = "PROFILE_MARKER",
		value = "FAIL",
	}
	secret_env[1] = {
		name      = "PROFILE_TOKEN",
		value     = "sensitive-profile-token",
		sensitive = true,
	}
	a.environment = secret_env
	testing.expect_value(t, profile_upsert(&a, nil, 3), Profile_Error.None)
	old_resolver := bridge_extension_bundle_resolver
	bridge_extension_bundle_resolver = p1c_test_bundle_resolver
	p1c_test_bundle_path = bundle
	defer {bridge_extension_bundle_resolver = old_resolver; p1c_test_bundle_path = ""}
	bridge_hub_handle_extension_install_command(
		nil,
		`{"command_id":"p1c-secret-error","provider":"claude","profile_id":"claude_a"}`,
	)
	response, found := bridge_runtime_cached_command("p1c-secret-error")
	testing.expect(
		t,
		found &&
		!strings.contains(response, "sensitive-profile-token") &&
		strings.contains(response, "[redacted]"),
	)
	progress := bridge_provider_extension_install_progress_json(
		"cmd",
		"claude",
		"succeeded",
		100,
		"done",
		"claude_b",
	)
	defer delete(progress)
	testing.expect(t, strings.contains(progress, `"profile_id":"claude_b"`))
}

@(test)
test_profile_uninstall_purges_selected_profile_store_only :: proc(t: ^testing.T) {
	st := p1c_test_setup(t); defer p1c_test_teardown(st)
	selected := profile_join(st.dir, "selected/bridge/provider_profiles.json")
	other := profile_join(st.dir, "other/bridge/provider_profiles.json")
	p1c_put(t, selected, "settings")
	p1c_put(t, profile_join(st.dir, "selected/bridge/profile-secrets/key.bin"), "secret")
	p1c_put(t, other, "other-settings")
	testing.expect(t, profile_purge_path(selected))
	testing.expect(
		t,
		!os.exists(selected) &&
		!os.exists(profile_join(st.dir, "selected/bridge/profile-secrets")),
	)
	testing.expect(t, os.exists(other))
}

p1c_test_bundle_path: string
p1c_test_bundle_resolver :: proc(provider: string, allocator := context.allocator) -> string {
	return strings.clone(p1c_test_bundle_path, allocator)
}

@(test)
test_profile_model_report_custom_view_keeps_observed_provenance :: proc(t:^testing.T) {
 observed:=Bridge_Provider_Models{provider=strings.clone("codex"),profile_id=strings.clone("codex_one"),has_snapshot=true}
 observed.models=make([]Bridge_Discovered_Model,1)
 observed.models[0]={model_id=strings.clone("observed"),label=strings.clone("Observed")}
 view:=bridge_models_with_custom(observed,[]string{"custom","observed"})
 defer bridge_models_destroy(&view)
 testing.expect_value(t,len(view.models),2)
 testing.expect_value(t,len(view.custom_models),2)
 decoded:[]Bridge_Discovered_Model
 testing.expect(t,json.unmarshal_string(view.observed_models_json,&decoded,allocator=context.temp_allocator)==nil)
 testing.expect_value(t,len(decoded),1)
 if len(decoded)==1 do testing.expect_value(t,decoded[0].model_id,"observed")
}
