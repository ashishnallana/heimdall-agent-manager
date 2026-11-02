package domain

Provider_Model :: struct {
	provider: string,
	model_id: string,
	label:    string,
	state:    string,
	rank:     int,
	resolved_model: string,
}

Provider_Catalog_Entry :: struct {
	provider:           string,
	display_name:       string,
	icon_url:           string,
	binary:             string,
	base_args_json:     string,
	yolo_args_json:     string,
	// ask_args_json is appended instead of yolo_args when the effective
	// permission_mode is 'ask' (JSON array, '[]' when the provider needs none).
	ask_args_json:      string,
	model_flag:         string,
	prompt_args_json:   string,
	prompt_delivery:    string,
	starter_prompt:     string,
	bootstrap_file:     string,
	skill_dir:           string,
	startup_detection_json:  string,
	activity_detection_json: string,
	// extension_json is the catalog's extension descriptor object, or "" when the
	// provider has no extension (catalog column NULL, wire value null).
	extension_json:          string,
	state:               string,
	rank:                int,
	models:              [dynamic]Provider_Model,
}

Provider_Icon :: struct {
	provider:     string,
	content_type: string,
	content:      string,
}

Bridge_Provider_Status :: struct {
	profile_id: string,
	bridge_id: string,
	provider: string,
	binary_path: string,
	version_text: string,
	state: string,
	checked_at: string,
	// Extension probe result (REQ-EXT-DET-1). extension_state is one of
	// present|disabled|outdated|absent|error|unsupported, or "" if never reported.
	extension_state: string,
	extension_version: string,
	extension_checked_at: string,
}

Bridge_Provider_Setting :: struct {
	profile_id: string,
	bridge_id: string,
	provider: string,
	enabled: bool,
	updated_at: string,
}

provider_model_destroy :: proc(model: Provider_Model) {
	delete(model.provider)
	delete(model.model_id)
	delete(model.label)
	delete(model.state)
	delete(model.resolved_model)
}

provider_catalog_entry_destroy :: proc(entry: Provider_Catalog_Entry) {
	delete(entry.provider)
	delete(entry.display_name)
	delete(entry.icon_url)
	delete(entry.binary)
	delete(entry.base_args_json)
	delete(entry.yolo_args_json)
	delete(entry.ask_args_json)
	delete(entry.model_flag)
	delete(entry.prompt_args_json)
	delete(entry.prompt_delivery)
	delete(entry.starter_prompt)
	delete(entry.bootstrap_file)
	delete(entry.skill_dir)
	delete(entry.startup_detection_json)
	delete(entry.activity_detection_json)
	delete(entry.extension_json)
	delete(entry.state)
	for model in entry.models do provider_model_destroy(model)
	delete(entry.models)
}

provider_catalog_destroy :: proc(entries: [dynamic]Provider_Catalog_Entry) {
	for entry in entries do provider_catalog_entry_destroy(entry)
	delete(entries)
}

provider_icon_destroy :: proc(icon: Provider_Icon) {
	delete(icon.provider)
	delete(icon.content_type)
	delete(icon.content)
}

bridge_provider_status_destroy :: proc(value: Bridge_Provider_Status) {
	delete(value.profile_id); delete(value.bridge_id); delete(value.provider); delete(value.binary_path)
	delete(value.version_text); delete(value.state); delete(value.checked_at)
	delete(value.extension_state); delete(value.extension_version); delete(value.extension_checked_at)
}

bridge_provider_statuses_destroy :: proc(values: [dynamic]Bridge_Provider_Status) {
	for value in values do bridge_provider_status_destroy(value)
	delete(values)
}

bridge_provider_setting_destroy :: proc(value: Bridge_Provider_Setting) {
	delete(value.profile_id); delete(value.bridge_id); delete(value.provider); delete(value.updated_at)
}

bridge_provider_settings_destroy :: proc(values: [dynamic]Bridge_Provider_Setting) {
	for value in values do bridge_provider_setting_destroy(value)
	delete(values)
}

// Durable command tracking also carries per-update consent across reconnects.
Provider_Extension_Command :: struct {
	profile_id: string,
	command_id, bridge_id, kind, provider, parent_id:                             string,
	state, message, target_version, target_commit, source_version, source_commit: string,
	update_extensions:                                                            bool,
	progress:                                                                     int,
}
provider_extension_command_destroy :: proc(value: Provider_Extension_Command) {
	delete(value.profile_id); delete(value.command_id); delete(value.bridge_id); delete(value.kind)
	delete(value.provider); delete(value.parent_id); delete(value.state)
	delete(value.message); delete(value.target_version); delete(value.target_commit)
	delete(value.source_version); delete(value.source_commit)
}
provider_extension_commands_destroy :: proc(values: [dynamic]Provider_Extension_Command) {
	for value in values do provider_extension_command_destroy(value)
	delete(values)
}

// Independent of binary/extension detection; only explicit model refresh writes it.
Bridge_Provider_Models :: struct {
	custom_models_json:string,
	profile_id: string,
	bridge_id, provider, binary_path, version_text: string,
	has_snapshot: bool,
	models_json, models_source, models_checked_at, models_attempted_at, models_state: string,
}
bridge_provider_models_destroy :: proc(v: Bridge_Provider_Models) {
	delete(v.custom_models_json); delete(v.profile_id); delete(v.bridge_id); delete(v.provider); delete(v.binary_path); delete(v.version_text)
	delete(v.models_json); delete(v.models_source); delete(v.models_checked_at)
	delete(v.models_attempted_at); delete(v.models_state)
}
bridge_provider_models_list_destroy :: proc(values: [dynamic]Bridge_Provider_Models) {
	for v in values do bridge_provider_models_destroy(v)
	delete(values)
}

profile_effective_id :: proc(provider, id: string) -> string {
 return id if id != "" else provider
}
Bridge_Provider_Profile :: struct {
 bridge_id: string,
 profile_id: string `json:"profile_id"`,
 provider: string `json:"provider"`,
 label_enc: string `json:"label_enc"`,
 accent: string `json:"accent"`,
 enabled: bool `json:"enabled"`,
 has_config_dir: bool `json:"has_config_dir"`,
 has_home_path: bool `json:"has_home_path"`,
 has_shadow_home_path: bool `json:"has_shadow_home_path"`,
 has_binary: bool `json:"has_binary"`,
 env_count: int `json:"env_count"`,
 args_count: int `json:"args_count"`,
 custom_models_count: int `json:"custom_models_count"`,
 state: string `json:"state"`,
 created_at: i64 `json:"created_at"`,
 updated_at: i64 `json:"updated_at"`,
}
bridge_provider_profile_destroy :: proc(p: Bridge_Provider_Profile) {
 delete(p.bridge_id); delete(p.profile_id); delete(p.provider); delete(p.label_enc); delete(p.accent); delete(p.state)
}
bridge_provider_profiles_destroy :: proc(ps: [dynamic]Bridge_Provider_Profile) {
 for p in ps do bridge_provider_profile_destroy(p)
 delete(ps)
}
