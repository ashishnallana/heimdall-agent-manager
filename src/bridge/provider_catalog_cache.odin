package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import cfg_lib "odin_test:lib/config"
import ws "odin_test:lib/ws"

Bridge_Catalog_Model :: struct {
	model_id: string `json:"model_id"`,
	label:    string `json:"label"`,
	state:    string `json:"state"`,
}

Bridge_Catalog_Provider :: struct {
	provider:           string `json:"provider"`,
	display_name:       string `json:"display_name"`,
	icon_url:           string `json:"icon_url"`,
	binary:             string `json:"binary"`,
	base_args:          []string `json:"base_args"`,
	yolo_args:          []string `json:"yolo_args"`,
	// Appended instead of yolo_args for permission_mode 'ask'; absent from a Hub
	// that predates it (nil, so ask mode just omits the yolo flags).
	ask_args:           []string `json:"ask_args"`,
	model_flag:         string `json:"model_flag"`,
	prompt_args:        []string `json:"prompt_args"`,
	prompt_delivery:    string `json:"prompt_delivery"`,
	starter_prompt:     string `json:"starter_prompt"`,
	bootstrap_file:     string `json:"bootstrap_file"`,
	skill_dir:           string `json:"skill_dir"`,
	startup_detection:  cfg_lib.Startup_Detection_Config `json:"startup_detection"`,
	activity_detection: cfg_lib.Activity_Detection_Config `json:"activity_detection"`,
	// Zero value (catalog `null` or a Hub that predates it) means unsupported.
	extension:          Bridge_Catalog_Extension `json:"extension"`,
	state:               string `json:"state"`,
	models:              []Bridge_Catalog_Model `json:"models"`,
}

Bridge_Provider_Catalog_Wire :: struct {
	providers: []Bridge_Catalog_Provider `json:"providers"`,
}

Bridge_Provider_Catalog_Snapshot :: struct {
	etag:         string,
	catalog_json: string,
	providers:    []Bridge_Catalog_Provider,
}

bridge_provider_catalog_mutex: sync.RW_Mutex
bridge_provider_catalog_loaded: bool
bridge_provider_catalog_snapshot: ^Bridge_Provider_Catalog_Snapshot

bridge_provider_catalog_path :: proc() -> string {
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do data_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(data_dir)
	defer if raw_data(expanded) != raw_data(data_dir) do delete(expanded)
	return strings.concatenate({strings.trim_right(expanded, "/"), "/bridge/provider_catalog.json"})
}

// bridge_provider_catalog_name_supported accepts any well-formed provider slug
// (lowercase letters, digits, and inner dashes, at most 32 bytes). The Hub's
// catalog is the source of truth for which providers exist, so adding one needs
// no Bridge release. Bridges up to v0.3.39 hard-coded exactly four names and
// reject a catalog that adds a provider, keeping their cached copy instead.
bridge_provider_catalog_name_supported :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 32 do return false
	if name[0] == '-' || name[len(name) - 1] == '-' do return false
	for c in transmute([]u8)name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') do return false
	}
	return true
}

bridge_provider_catalog_valid :: proc(catalog: Bridge_Provider_Catalog_Wire) -> bool {
	if len(catalog.providers) == 0 do return false
	for provider, i in catalog.providers {
		if !bridge_provider_catalog_name_supported(provider.provider) do return false
		if strings.trim_space(provider.display_name) == "" || strings.trim_space(provider.binary) == "" do return false
		if provider.state != "active" && provider.state != "deprecated" do return false
		if len(provider.models) == 0 do return false
		for previous in 0..<i {
			if catalog.providers[previous].provider == provider.provider do return false
		}
		for model, model_index in provider.models {
			if strings.trim_space(model.model_id) == "" || strings.trim_space(model.label) == "" do return false
			if model.state != "active" && model.state != "deprecated" do return false
			for previous_model in 0..<model_index {
				if provider.models[previous_model].model_id == model.model_id do return false
			}
		}
	}
	return true
}

bridge_provider_catalog_build_snapshot :: proc(etag, catalog_json: string) -> (^Bridge_Provider_Catalog_Snapshot, bool) {
	if !strings.has_prefix(etag, "sha256:") || !bootstrap_cache_verify_hash(catalog_json, etag) do return nil, false
	wire: Bridge_Provider_Catalog_Wire
	if err := json.unmarshal_string(catalog_json, &wire, json.DEFAULT_SPECIFICATION, runtime.default_allocator()); err != nil do return nil, false
	if !bridge_provider_catalog_valid(wire) do return nil, false
	// This runs on the Hub WebSocket reader thread. Never replace that thread's
	// context allocator: values allocated before this call have deferred frees
	// that must continue using the allocator which created them. The immutable
	// process-lifetime snapshot alone is explicitly allocated from the runtime
	// allocator.
	snapshot := new(Bridge_Provider_Catalog_Snapshot, runtime.default_allocator())
	snapshot.etag = strings.clone(etag, runtime.default_allocator())
	snapshot.catalog_json = strings.clone(catalog_json, runtime.default_allocator())
	snapshot.providers = wire.providers
	return snapshot, true
}

bridge_provider_catalog_publish :: proc(snapshot: ^Bridge_Provider_Catalog_Snapshot) {
	if snapshot == nil do return
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	// Published snapshots are immutable and intentionally retained for the process
	// lifetime. A launch may still hold owned argv derived under the read lock; with
	// four providers and rare catalog edits, retaining a few KB avoids the same
	// replace-vs-reader use-after-free class documented in AGENTS.md.
	bridge_provider_catalog_snapshot = snapshot
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
}

bridge_provider_catalog_save :: proc(etag, catalog_json: string) -> bool {
	path := bridge_provider_catalog_path()
	defer delete(path)
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		if mk_err := bridge_make_directory_all(path[:slash]); mk_err != nil && !os.exists(path[:slash]) {
			fmt.eprintfln("bridge provider catalog: cannot create cache directory %s: %v", path[:slash], mk_err)
			return false
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"catalog_etag\":\"")
	bridge_runtime_write_json_string(&b, etag)
	strings.write_string(&b, "\",\"catalog_json\":\"")
	bridge_runtime_write_json_string(&b, catalog_json)
	strings.write_string(&b, "\"}\n")
	payload := strings.to_string(b)
	defer delete(payload)
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)
	if w_err := os.write_entire_file(tmp, transmute([]byte)payload); w_err != nil {
		fmt.eprintfln("bridge provider catalog: cannot write cache %s: %v", tmp, w_err)
		return false
	}
	if rn_err := os.rename(tmp, path); rn_err != nil {
		fmt.eprintfln("bridge provider catalog: cannot rename cache %s -> %s: %v", tmp, path, rn_err)
		_ = os.remove(tmp)
		return false
	}
	return true
}

bridge_provider_catalog_apply :: proc(etag, catalog_json: string) -> bool {
	snapshot, ok := bridge_provider_catalog_build_snapshot(etag, catalog_json)
	if !ok do return false
	if !bridge_provider_catalog_save(etag, catalog_json) do return false
	bridge_provider_catalog_publish(snapshot)
	return true
}

bridge_provider_catalog_init :: proc() {
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_loaded {
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
		return
	}
	bridge_provider_catalog_loaded = true
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)

	path := bridge_provider_catalog_path()
	defer delete(path)
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(raw)
	body := string(raw)
	etag := extract_json_string(body, "catalog_etag", "")
	defer delete(etag)
	catalog_json := extract_json_string(body, "catalog_json", "")
	defer delete(catalog_json)
	snapshot, ok := bridge_provider_catalog_build_snapshot(etag, catalog_json)
	if ok do bridge_provider_catalog_publish(snapshot)
}

bridge_provider_catalog_current_etag :: proc() -> string {
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return ""
	return strings.clone(bridge_provider_catalog_snapshot.etag)
}

// Returns a catalog-backed profile whose strings remain valid for the process
// lifetime. Published catalog snapshots are immutable and intentionally retained.
// There is no default-provider fallback: callers must name an active provider.
bridge_provider_catalog_profile :: proc(name: string) -> (Bridge_Provider_Profile, bool) {
	if strings.trim_space(name) == "" do return {}, false
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return {}, false
	for provider in bridge_provider_catalog_snapshot.providers {
		if provider.provider != name || provider.state != "active" do continue
		return bridge_provider_profile_from_catalog(provider), true
	}
	return {}, false
}

// Projects one catalog entry onto the launch profile. The result aliases the
// entry's strings, so it lives as long as the snapshot that owns the entry.
bridge_provider_profile_from_catalog :: proc(provider: Bridge_Catalog_Provider) -> Bridge_Provider_Profile {
	return Bridge_Provider_Profile{
		name = provider.provider,
		base_args = provider.base_args,
		yolo_flags = provider.yolo_args,
		ask_flags = provider.ask_args,
		prompt_flags = provider.prompt_args,
		starter_prompt = provider.starter_prompt,
		extension = provider.extension,
		prompt_delivery = provider.prompt_delivery,
		skill_dir = provider.skill_dir,
		bootstrap_file_name = provider.bootstrap_file,
		model_flag = provider.model_flag,
		startup_detection = provider.startup_detection,
		activity_detection = provider.activity_detection,
	}
}

bridge_provider_catalog_has_model :: proc(provider_name, model_id: string) -> bool {
	if strings.trim_space(provider_name) == "" || strings.trim_space(model_id) == "" do return false
	observed := bridge_models_get(provider_name)
	defer bridge_models_destroy(&observed)
	if observed.has_snapshot {
		if _, active := bridge_provider_catalog_profile(provider_name); !active do return false
		for model in observed.models do if model.model_id==model_id do return true
		return false
	}
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return false
	for provider in bridge_provider_catalog_snapshot.providers {
		if provider.provider != provider_name || provider.state != "active" do continue
		for model in provider.models {
			if model.model_id == model_id && model.state == "active" do return true
		}
	}
	return false
}

bridge_provider_catalog_needs_sync :: proc(hub_etag: string) -> bool {
	if strings.trim_space(hub_etag) == "" do return false
	current := bridge_provider_catalog_current_etag()
	defer delete(current)
	return !strings.equal_fold(current, hub_etag)
}

bridge_provider_catalog_request_json :: proc() -> string {
	current := bridge_provider_catalog_current_etag()
	defer delete(current)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_catalog_request\",\"cached_etag\":\"")
	bridge_runtime_write_json_string(&b, current)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_provider_catalog_handle_frame :: proc(conn: ^ws.Connection, frame_type, text: string) -> bool {
	if frame_type == "provider_catalog_version" {
		hub_etag := extract_json_string(text, "catalog_etag", "")
		defer delete(hub_etag)
		if bridge_provider_catalog_needs_sync(hub_etag) {
			request := bridge_provider_catalog_request_json()
			defer delete(request)
			_ = bridge_hub_send(conn, request)
		}
		// The hub sends its catalog version on every connect: report profiles then.
		bridge_send_provider_profiles_report(conn)
		return true
	}
	if frame_type != "provider_catalog" do return false
	etag := extract_json_string(text, "catalog_etag", "")
	defer delete(etag)
	catalog_json := extract_json_string(text, "catalog_json", "")
	defer delete(catalog_json)
	if !bridge_provider_catalog_apply(etag, catalog_json) {
		// bridge_provider_catalog_save prints its own reason when the cache write
		// is what failed; a silent false here means the body itself was bad.
		fmt.println("bridge provider catalog rejected: malformed body, sha256 mismatch, or cache not persisted (see above)")
	} else {
		// A new catalog can turn a custom profile id into a slug clash.
		bridge_send_provider_profiles_report(conn)
	}
	return true
}
