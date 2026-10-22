package domain

Provider_Model :: struct {
	provider: string,
	model_id: string,
	label:    string,
	state:    string,
	rank:     int,
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
	delete(value.bridge_id); delete(value.provider); delete(value.binary_path)
	delete(value.version_text); delete(value.state); delete(value.checked_at)
	delete(value.extension_state); delete(value.extension_version); delete(value.extension_checked_at)
}

bridge_provider_statuses_destroy :: proc(values: [dynamic]Bridge_Provider_Status) {
	for value in values do bridge_provider_status_destroy(value)
	delete(values)
}

bridge_provider_setting_destroy :: proc(value: Bridge_Provider_Setting) {
	delete(value.bridge_id); delete(value.provider); delete(value.updated_at)
}

bridge_provider_settings_destroy :: proc(values: [dynamic]Bridge_Provider_Setting) {
	for value in values do bridge_provider_setting_destroy(value)
	delete(values)
}
