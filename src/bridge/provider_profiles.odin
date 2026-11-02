package main

// Provider profiles: trusted-host settings in a plain 0600 JSON file. Sensitive
// values live in separate 0600 files under profile-secrets/ (0700), as in t3code.
// Vault keys protect operations in transit only; local launches need no vault.

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import vault "odin_test:lib/vault"

PROFILE_ID_MAX :: 32
PROFILE_ENV_MAX :: 64
PROFILE_ENV_NAME_MAX :: 128
PROFILE_ENV_VALUE_MAX :: 8 * 1024
PROFILE_ARGS_MAX :: 32
PROFILE_ARG_MAX :: 1024
PROFILE_PATH_MAX :: 4096
PROFILE_LABEL_ENC_MAX :: 4096
PROFILE_STORE_MAX :: 256
PROFILE_STORE_VERSION :: 2

Provider_Profile_Env :: struct {
	name:           string `json:"name"`,
	value:          string `json:"value"`,
	sensitive:      bool `json:"sensitive"`,
	value_redacted: bool `json:"value_redacted"`,
}

// A driver-tagged config: provider selects the supported fields, checked below.
// Empty fields use the discovered binary / inherited driver directory.
Provider_Profile_Config :: struct {
	binary_path:      string `json:"binary_path"`,
	config_dir:       string `json:"config_dir"`, // claude
	home_path:        string `json:"home_path"`, // codex
	shadow_home_path: string `json:"shadow_home_path"`, // prepared by P1c
	launch_args:      string `json:"launch_args"`,
	custom_models:    []string `json:"custom_models"`,
	auth_method:      string `json:"auth_method"`, // antigravity
	api_key:          string `json:"api_key"`,
	api_key_redacted: bool `json:"api_key_redacted"`,
	gcp_project:      string `json:"gcp_project"`,
	gcp_location:     string `json:"gcp_location"`,
}

Provider_Profile :: struct {
	profile_id:  string `json:"profile_id"`,
	provider:    string `json:"provider"`,
	label_enc:   string `json:"label_enc"`,
	accent:      string `json:"accent"`,
	enabled:     bool `json:"enabled"`,
	environment: []Provider_Profile_Env `json:"environment"`,
	config:      Provider_Profile_Config `json:"config"`,
	created_at:  i64 `json:"created_at"`,
	updated_at:  i64 `json:"updated_at"`,
}

Provider_Profile_Record_Wire :: Provider_Profile
Provider_Profile_Store_Wire :: struct {
	version:  int `json:"version"`,
	profiles: []Provider_Profile_Record_Wire `json:"profiles"`,
}

Profile_Error :: enum {
	None,
	Invalid_Id,
	Reserved_Id,
	Unknown_Provider,
	Provider_Mismatch,
	Invalid_Accent,
	Invalid_Label,
	Path_Invalid,
	Binary_Invalid,
	Config_Dir_Unsupported,
	Config_Invalid,
	Env_Invalid,
	Env_Forbidden,
	Args_Invalid,
	Not_Found,
	Default_Not_Removable,
	Store_Full,
	Store_Unavailable,
	Unknown,
	Disabled,
	Slug_Clash,
	Shadow_Home_Invalid,
}
profile_error_code :: proc(e: Profile_Error) -> string {
	switch e {
	case .None:
		return ""
	case .Invalid_Id:
		return "profile_invalid_id"
	case .Reserved_Id:
		return "profile_reserved_id"
	case .Unknown_Provider:
		return "profile_unknown_provider"
	case .Provider_Mismatch:
		return "profile_provider_mismatch"
	case .Invalid_Accent:
		return "profile_invalid_accent"
	case .Invalid_Label:
		return "profile_invalid_label"
	case .Path_Invalid:
		return "profile_path_invalid"
	case .Binary_Invalid:
		return "profile_binary_invalid"
	case .Config_Dir_Unsupported:
		return "profile_config_dir_unsupported"
	case .Config_Invalid:
		return "profile_config_invalid"
	case .Env_Invalid:
		return "profile_env_invalid"
	case .Env_Forbidden:
		return "profile_env_forbidden"
	case .Args_Invalid:
		return "profile_args_invalid"
	case .Not_Found:
		return "profile_not_found"
	case .Default_Not_Removable:
		return "profile_default_not_removable"
	case .Store_Full:
		return "profile_store_full"
	case .Store_Unavailable:
		return "profile_store_unavailable"
	case .Unknown:
		return "profile_unknown"
	case .Disabled:
		return "profile_disabled"
	case .Slug_Clash:
		return "profile_slug_clash"
	case .Shadow_Home_Invalid:
		return "profile_shadow_home_invalid"
	}
	return "profile_error"
}

profile_id_valid :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > PROFILE_ID_MAX do return false
	if !(id[0] >= 'a' && id[0] <= 'z') do return false
	for c in transmute([]u8)id {
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok do return false
	}
	return true
}

profile_env_name_valid :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > PROFILE_ENV_NAME_MAX do return false
	c0 := name[0]
	if !((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_') do return false
	for c in transmute([]u8)name {
		ok :=
			(c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
		if !ok do return false
	}
	return true
}

profile_accent_valid :: proc(accent: string) -> bool {
	if accent == "" do return true
	if len(accent) != 7 || accent[0] != '#' do return false
	for c in transmute([]u8)accent[1:] {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) do return false
	}
	return true
}

profile_has_nul :: proc(s: string) -> bool {
	return strings.index_byte(s, 0) >= 0
}

// profile_path_absolute checks an override path after profile_normalize_path:
// absolute, bounded, no NUL.
profile_path_absolute :: proc(p: string) -> bool {
	if p == "" || len(p) > PROFILE_PATH_MAX || profile_has_nul(p) do return false
	return filepath.is_abs(p)
}

// profile_normalize_path expands a leading `~` against the bridge's HOME (the
// browser cannot know it) and cleans "." / ".." lexically; symlinks are never
// resolved. "" stays "". The result is what gets stored.
profile_normalize_path :: proc(p: string, allocator := context.temp_allocator) -> string {
	s := strings.trim_space(p)
	if s == "" do return ""
	if s == "~" do s = "~/"
	if strings.has_prefix(s, "~/") {
		expanded := bridge_expand_home(s)
		if raw_data(expanded) != raw_data(s) {
			defer delete(expanded)
			s = strings.clone(expanded, allocator)
		}
	}
	if !filepath.is_abs(s) do return s // refused by validation
	cleaned, _ := filepath.clean(s, allocator)
	return cleaned
}

// profile_catalog_has is the catalog lookup used by validation; a test seam lets
// unit tests run without a cached catalog.
profile_catalog_has :: proc(provider: string) -> bool {
	when ODIN_TEST {
		if len(g_profile_test_catalog) > 0 do return slice.contains(g_profile_test_catalog, provider)
	}
	_, ok := bridge_provider_catalog_profile(provider)
	return ok
}

// Test seams (only read under ODIN_TEST; declared always so `odin check` of the
// test files type-checks).
g_profile_test_catalog: []string

// profile_validate_metadata checks id namespace and metadata (amendment 1 §2).
profile_validate_metadata :: proc(p: ^Provider_Profile) -> Profile_Error {
	if !profile_id_valid(p.profile_id) do return .Invalid_Id
	if !profile_catalog_has(p.provider) do return .Unknown_Provider
	// The default profile's id is its provider slug; no other profile may take any slug.
	if p.profile_id != p.provider && profile_catalog_has(p.profile_id) do return .Reserved_Id
	if !profile_accent_valid(p.accent) do return .Invalid_Accent
	if p.label_enc != "" && (len(p.label_enc) > PROFILE_LABEL_ENC_MAX || !vault.is_armored(p.label_enc)) do return .Invalid_Label
	return .None
}


// Same quote/backslash rules as t3code tokenizeCliArgs. No shell expansion.
// Empty quoted arguments are dropped per the profile launch contract.
profile_tokenize_args :: proc(input: string, allocator := context.temp_allocator) -> []string {
	tokens := make([dynamic]string, allocator)
	current := make([dynamic]byte, context.temp_allocator)
	quote: byte
	for i := 0; i < len(input); i += 1 {
		c := input[i]
		if quote != 0 {
			if c == quote {
				quote = 0
			} else if c == '\\' &&
			   quote == '"' &&
			   i + 1 < len(input) &&
			   (input[i + 1] == '"' ||
					   input[i + 1] == '\\' ||
					   input[i + 1] == '$' ||
					   input[i + 1] == '`') {
				i += 1
				append(&current, input[i])
			} else {
				append(&current, c)
			}
		} else if c == '\'' || c == '"' {
			quote = c
		} else if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			if len(current) > 0 {
				append(&tokens, strings.clone(string(current[:]), allocator))
				clear(&current)
			}
		} else if c == '\\' &&
		   i + 1 < len(input) &&
		   (input[i + 1] == ' ' ||
				   input[i + 1] == '\t' ||
				   input[i + 1] == '\r' ||
				   input[i + 1] == '\n' ||
				   input[i + 1] == '\'' ||
				   input[i + 1] == '"') {
			i += 1
			append(&current, input[i])
		} else {
			append(&current, c)
		}
	}
	if len(current) > 0 do append(&tokens, strings.clone(string(current[:]), allocator))
	return tokens[:]
}

profile_normalize :: proc(p: ^Provider_Profile) {
	c := &p.config
	c.binary_path = strings.trim_space(c.binary_path)
	// Bare executable names use PATH; paths are expanded/cleaned on the bridge.
	if strings.contains_any(c.binary_path, "/\\") || c.binary_path == "~" {
		c.binary_path = profile_normalize_path(c.binary_path)
	}
	c.config_dir = profile_normalize_path(c.config_dir)
	c.home_path = profile_normalize_path(c.home_path)
	c.shadow_home_path = profile_normalize_path(c.shadow_home_path)
	c.launch_args = strings.trim_space(c.launch_args)
}

profile_validate :: proc(p: ^Provider_Profile) -> Profile_Error {
	c := &p.config
	if c.binary_path != "" {
		if profile_has_nul(c.binary_path) || len(c.binary_path) > PROFILE_PATH_MAX do return .Path_Invalid
		if strings.contains_any(c.binary_path, "/\\") {
			if !profile_path_absolute(c.binary_path) do return .Path_Invalid
			info, err := os.stat(c.binary_path, context.temp_allocator)
			if err != nil || info.type != .Regular || !bridge_os_is_executable(c.binary_path) do return .Binary_Invalid
		}
	}
	for path in ([]string{c.config_dir, c.home_path, c.shadow_home_path}) {
		if path != "" && !profile_path_absolute(path) do return .Path_Invalid
	}
	if c.config_dir != "" && p.provider != "claude" do return .Config_Dir_Unsupported
	if (c.home_path != "" || c.shadow_home_path != "") && p.provider != "codex" do return .Config_Invalid
	ag_config :=
		c.auth_method != "" ||
		c.api_key != "" ||
		c.api_key_redacted ||
		c.gcp_project != "" ||
		c.gcp_location != ""
	if ag_config && p.provider != "antigravity" do return .Config_Invalid
	if p.provider == "antigravity" {
		if c.launch_args != "" || len(c.custom_models) > 0 do return .Config_Invalid
		if c.auth_method != "" && !slice.contains([]string{"oauth-personal", "oauth-business", "gemini-api-key", "agent-platform"}, c.auth_method) do return .Config_Invalid
	}
	for value in ([]string{c.api_key, c.gcp_project, c.gcp_location}) {
		if len(value) > PROFILE_ENV_VALUE_MAX || profile_has_nul(value) do return .Config_Invalid
	}
	if len(p.environment) > PROFILE_ENV_MAX do return .Env_Invalid
	seen := make(map[string]bool, context.temp_allocator)
	for e in p.environment {
		if !profile_env_name_valid(e.name) || len(e.value) > PROFILE_ENV_VALUE_MAX || profile_has_nul(e.value) || seen[e.name] do return .Env_Invalid
		seen[e.name] = true
		// Windows env names are case-insensitive too.
		name := strings.to_upper(e.name, context.temp_allocator)
		if strings.has_prefix(name, "HEIMDALL_") || name == "HOME" || name == "USERPROFILE" do return .Env_Forbidden
	}
	if len(c.launch_args) > PROFILE_ARGS_MAX * PROFILE_ARG_MAX || profile_has_nul(c.launch_args) do return .Args_Invalid
	args := profile_tokenize_args(c.launch_args)
	if len(args) > PROFILE_ARGS_MAX do return .Args_Invalid
	for a in args do if len(a) > PROFILE_ARG_MAX do return .Args_Invalid
	if len(c.custom_models) > PROFILE_STORE_MAX do return .Config_Invalid
	for model in c.custom_models {
		if !bridge_model_id_valid(model) do return .Config_Invalid
	}
	return .None
}

// Preserve the existing leaf-only creation rule. Codex shadow setup is P1c.
profile_prepare_dirs :: proc(c: ^Provider_Profile_Config) -> Profile_Error {
	for dir in ([]string{c.config_dir, c.home_path}) {
		if dir == "" do continue
		if info, err := os.stat(dir, context.temp_allocator); err == nil {
			if info.type != .Directory do return .Path_Invalid
			continue
		}
		info, err := os.stat(filepath.dir(dir), context.temp_allocator)
		if err != nil || info.type != .Directory do return .Path_Invalid
		if os.make_directory(dir, {.Read_User, .Write_User, .Execute_User}) != nil && !os.is_dir(dir) do return .Path_Invalid
	}
	return .None
}

Profile_Env_Plan :: struct {
	set:   [dynamic][2]string,
	unset: [dynamic]string,
}

profile_env_set :: proc(plan: ^Profile_Env_Plan, name, value: string) {
	for &kv in plan.set {
		when ODIN_OS == .Windows {
			if strings.equal_fold(kv[0], name) {kv = {name, value}; return}
		} else {
			if kv[0] == name {kv[1] = value; return}
		}
	}
	append(&plan.set, [2]string{name, value})
}

// bridge env -> profile environment -> forced driver dir -> launcher HEIMDALL_*.
// HOME is inherited unchanged. A directory config wins over an env entry.
profile_env_plan :: proc(
	p: ^Provider_Profile,
	allocator := context.temp_allocator,
) -> Profile_Env_Plan {
	plan := Profile_Env_Plan {
		set   = make([dynamic][2]string, allocator),
		unset = make([dynamic]string, allocator),
	}
	for e in p.environment do profile_env_set(&plan, e.name, e.value)
	c := &p.config
	if p.provider == "claude" && c.config_dir != "" {
		profile_env_set(&plan, "CLAUDE_CONFIG_DIR", c.config_dir)
	}
	if p.provider == "codex" {
		dir := c.shadow_home_path if c.shadow_home_path != "" else c.home_path
		if dir != "" do profile_env_set(&plan, "CODEX_HOME", dir)
	}
	if p.provider == "antigravity" {
		if c.api_key != "" do profile_env_set(&plan, "GEMINI_API_KEY", c.api_key)
		if c.gcp_project != "" do profile_env_set(&plan, "GOOGLE_CLOUD_PROJECT", c.gcp_project)
		if c.gcp_location != "" do profile_env_set(&plan, "GOOGLE_CLOUD_LOCATION", c.gcp_location)
	}
	return plan
}

profile_env_name_equal :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {return strings.equal_fold(a, b)} else {return a == b}
}

profile_apply_env_plan :: proc(
	base: []string,
	plan: Profile_Env_Plan,
	allocator := context.temp_allocator,
) -> []string {
	out := make([dynamic]string, allocator)
	for entry in base {
		eq := strings.index_byte(entry, '=')
		name := entry[:eq] if eq >= 0 else entry
		skip := false
		for u in plan.unset do if profile_env_name_equal(u, name) do skip = true
		for kv in plan.set do if profile_env_name_equal(kv[0], name) do skip = true
		if !skip do append(&out, entry)
	}
	for kv in plan.set do append(&out, strings.concatenate({kv[0], "=", kv[1]}, allocator))
	return out[:]
}

// Store globals are protected by a single mutex for reads, writes and materialization.
g_profile_store_mu: sync.Mutex
g_profile_test_store_path: string

profile_store_path :: proc(allocator := context.temp_allocator) -> string {
	when ODIN_TEST {
		if g_profile_test_store_path != "" do return strings.clone(g_profile_test_store_path, allocator)
	}
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do data_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(data_dir)
	defer if raw_data(expanded) != raw_data(data_dir) do delete(expanded)
	return strings.concatenate(
		{strings.trim_right(expanded, "/"), "/bridge/provider_profiles.json"},
		allocator,
	)
}

profile_secrets_dir :: proc() -> string {
	path, _ := filepath.join(
		{filepath.dir(profile_store_path()), "profile-secrets"},
		context.temp_allocator,
	)
	return path
}

profile_env_secret_name :: proc(id, name: string) -> string {
	return strings.concatenate(
		{
			"provider-env-",
			bridge_base64url_unpadded(transmute([]byte)id, context.temp_allocator),
			"-",
			bridge_base64url_unpadded(transmute([]byte)name, context.temp_allocator),
			".bin",
		},
		context.temp_allocator,
	)
}
profile_config_secret_name :: proc(id, provider, field: string) -> string {
	return strings.concatenate(
		{
			"provider-config-",
			bridge_base64url_unpadded(transmute([]byte)id, context.temp_allocator),
			"-",
			provider,
			"-",
			field,
			".bin",
		},
		context.temp_allocator,
	)
}
profile_secret_path :: proc(name: string) -> string {
	path, _ := filepath.join({profile_secrets_dir(), name}, context.temp_allocator)
	return path
}

profile_atomic_write :: proc(path: string, data: []byte) -> bool {
	dir := filepath.dir(path)
	if err := bridge_make_directory_all(dir); err != nil && !os.is_dir(dir) do return false
	when ODIN_OS != .Windows {
		if os.chmod(dir, {.Read_User, .Write_User, .Execute_User}) != nil do return false
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	_ = os.remove(tmp)
	f, err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return false
	n, werr := os.write(f, data)
	serr := os.sync(f)
	cerr := os.close(f)
	if werr != nil || n != len(data) || serr != nil || cerr != nil {
		_ = os.remove(tmp)
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

profile_store_read_locked :: proc(
	allocator := context.temp_allocator,
) -> (
	records: []Provider_Profile_Record_Wire,
	ok: bool,
) {
	path := profile_store_path()
	if !os.exists(path) do return nil, true
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil, false
	wire: Provider_Profile_Store_Wire
	if json.unmarshal(data, &wire, json.Specification.JSON, allocator) != nil || wire.version != PROFILE_STORE_VERSION do return nil, false
	return wire.profiles, true
}

profile_store_write_locked :: proc(records: []Provider_Profile_Record_Wire) -> bool {
	data, err := json.marshal(
		Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = records},
		allocator = context.temp_allocator,
	)
	if err != nil do return false
	return profile_atomic_write(profile_store_path(), data)
}

Profile_Secret_Field :: struct {
	name:      string,
	value:     ^string,
	redacted:  ^bool,
	sensitive: bool,
}

profile_secret_fields :: proc(p: ^Provider_Profile) -> []Profile_Secret_Field {
	out := make([dynamic]Profile_Secret_Field, context.temp_allocator)
	for &e in p.environment {
		append(
			&out,
			Profile_Secret_Field {
				profile_env_secret_name(p.profile_id, e.name),
				&e.value,
				&e.value_redacted,
				e.sensitive,
			},
		)
	}
	if p.provider == "antigravity" {
		append(
			&out,
			Profile_Secret_Field {
				profile_config_secret_name(p.profile_id, p.provider, "api_key"),
				&p.config.api_key,
				&p.config.api_key_redacted,
				true,
			},
		)
	}
	return out[:]
}

// Missing redacted values are empty, as in t3code; unreadable files fail closed.
profile_materialize :: proc(p: ^Provider_Profile) -> bool {
	for field in profile_secret_fields(p) {
		if !field.sensitive || !field.redacted^ do continue
		path := profile_secret_path(field.name)
		if !os.exists(path) {field.value^ = ""; continue}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil do return false
		field.value^ = string(data)
	}
	return true
}

// Lists are redacted even in local memory. Only launch/probe lookup opens secrets.
profile_list :: proc(allocator := context.temp_allocator) -> ([]Provider_Profile, Profile_Error) {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked(allocator)
	return records, .None if ok else .Store_Unavailable
}

profile_lookup :: proc(
	provider, profile_id: string,
	allocator := context.temp_allocator,
) -> (
	p: Provider_Profile,
	err: Profile_Error,
) {
	id := strings.trim_space(profile_id)
	if id == "" do id = provider
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked(allocator)
	if !ok do return {}, .Store_Unavailable
	for &rec in records {
		if rec.profile_id != id do continue
		if rec.provider != provider do return {}, .Slug_Clash if id == provider else .Provider_Mismatch
		if !rec.enabled do return {}, .Disabled
		p = rec
		if !profile_materialize(&p) do return {}, .Store_Unavailable
		if e := profile_prepare_runtime(&p); e != .None do return {}, e
		return p, .None
	}
	if id == provider do return Provider_Profile{profile_id = provider, provider = provider, enabled = true}, .None
	return {}, .Unknown
}

Profile_Secret_Change :: struct {
	name:   string,
	value:  string,
	remove: bool,
}
Profile_Secret_Snapshot :: struct {
	name:    string,
	value:   []byte,
	existed: bool,
}

// Persist redacted settings and secret changes together. All old bytes are read
// before mutation; failures restore already-applied writes in reverse order.
profile_commit_locked :: proc(
	records: []Provider_Profile_Record_Wire,
	changes: []Profile_Secret_Change,
) -> bool {
	snapshots := make([dynamic]Profile_Secret_Snapshot, context.temp_allocator)
	for c in changes {
		path := profile_secret_path(c.name)
		existed := os.exists(path)
		data: []byte
		if existed {
			err: os.Error
			data, err = os.read_entire_file(path, context.temp_allocator)
			if err != nil do return false
		}
		append(&snapshots, Profile_Secret_Snapshot{c.name, data, existed})
	}
	success := false
	applied := 0
	defer if !success {
		for i := applied - 1; i >= 0; i -= 1 {
			s := snapshots[i]
			path := profile_secret_path(s.name)
			if s.existed {_ = profile_atomic_write(path, s.value)} else {_ = os.remove(path)}
		}
	}
	for c in changes {
		applied += 1
		path := profile_secret_path(c.name)
		if c.remove {
			if os.exists(path) && os.remove(path) != nil do return false
		} else if !profile_atomic_write(path, transmute([]byte)c.value) {
			return false
		}
	}
	success = profile_store_write_locked(records)
	return success
}

// keep_names supports the earlier explicit keep bit; value_redacted is the
// t3code keep rule. Non-redacted empty clears; missing/non-sensitive removes.
profile_upsert :: proc(p: ^Provider_Profile, keep_names: []string, now: i64) -> Profile_Error {
	if e := profile_validate_metadata(p); e != .None do return e
	profile_normalize(p)
	if e := profile_validate(p); e != .None do return e
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	if !ok do return .Store_Unavailable
	idx := -1
	for rec, i in records do if rec.profile_id == p.profile_id do idx = i
	previous: Provider_Profile
	if idx >= 0 {
		previous = records[idx]
		if previous.provider != p.provider do return .Provider_Mismatch
		p.created_at = previous.created_at
	} else {
		if len(records) >= PROFILE_STORE_MAX do return .Store_Full
		p.created_at = now
	}
	if e := profile_prepare_dirs(&p.config); e != .None do return e
	p.updated_at = now
	stored := p^
	stored.environment = make([]Provider_Profile_Env, len(p.environment), context.temp_allocator)
	copy(stored.environment, p.environment)
	changes := make([dynamic]Profile_Secret_Change, context.temp_allocator)
	retained := make(map[string]bool, context.temp_allocator)
	for field in profile_secret_fields(&stored) {
		retained[field.name] = true
		if !field.sensitive {
			field.redacted^ = false
			append(&changes, Profile_Secret_Change{name = field.name, remove = true})
			continue
		}
		keep := field.redacted^
		for e in p.environment {
			if field.name == profile_env_secret_name(p.profile_id, e.name) && slice.contains(keep_names, e.name) && e.value == "" do keep = true
		}
		if keep {
			field.value^ = ""
			field.redacted^ = true
		} else if field.value^ == "" {
			field.redacted^ = false
			append(&changes, Profile_Secret_Change{name = field.name, remove = true})
		} else {
			append(&changes, Profile_Secret_Change{name = field.name, value = field.value^})
			field.value^ = ""
			field.redacted^ = true
		}
	}
	for field in profile_secret_fields(&previous) {
		if field.sensitive && !retained[field.name] do append(&changes, Profile_Secret_Change{name = field.name, remove = true})
	}
	next := make([dynamic]Provider_Profile_Record_Wire, context.temp_allocator)
	for rec, i in records do append(&next, stored if i == idx else rec)
	if idx < 0 do append(&next, stored)
	return .None if profile_commit_locked(next[:], changes[:]) else .Store_Unavailable
}

profile_remove :: proc(profile_id: string) -> Profile_Error {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	if !ok do return .Store_Unavailable
	next := make([dynamic]Provider_Profile_Record_Wire, context.temp_allocator)
	changes := make([dynamic]Profile_Secret_Change, context.temp_allocator)
	found := false
	for &rec in records {
		if rec.profile_id != profile_id {append(&next, rec); continue}
		if rec.profile_id == rec.provider do return .Default_Not_Removable
		found = true
		for field in profile_secret_fields(&rec) do if field.sensitive do append(&changes, Profile_Secret_Change{name = field.name, remove = true})
	}
	if !found do return .Default_Not_Removable if profile_catalog_has(profile_id) else .Not_Found
	return .None if profile_commit_locked(next[:], changes[:]) else .Store_Unavailable
}

// Reset drops all overrides, including secrets, but preserves enabled.
profile_reset :: proc(provider: string) -> Profile_Error {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	if !ok do return .Store_Unavailable
	next := make([dynamic]Provider_Profile_Record_Wire, context.temp_allocator)
	changes := make([dynamic]Profile_Secret_Change, context.temp_allocator)
	changed := false
	for &rec in records {
		if rec.profile_id != provider || rec.provider != provider {append(&next, rec); continue}
		changed = true
		for field in profile_secret_fields(&rec) do if field.sensitive do append(&changes, Profile_Secret_Change{name = field.name, remove = true})
		if !rec.enabled do append(&next, Provider_Profile_Record_Wire{profile_id = rec.profile_id, provider = rec.provider, enabled = false, created_at = rec.created_at, updated_at = profile_now_ms()})
	}
	if !changed do return .None
	return .None if profile_commit_locked(next[:], changes[:]) else .Store_Unavailable
}

profile_purge :: proc() -> bool {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	return profile_purge_path(profile_store_path())
}

// Lifecycle commands select their own layout, not the daemon's global config.
profile_purge_path :: proc(path: string) -> bool {
	dir := profile_join(filepath.dir(path),"profile-secrets")
	if os.exists(dir) && os.remove_all(dir) != nil do return false
	return !os.exists(path) || os.remove(path) == nil
}

profile_now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

Provider_Profile_Report_Entry :: struct {
	profile_id:           string `json:"profile_id"`,
	provider:             string `json:"provider"`,
	label_enc:            string `json:"label_enc"`,
	accent:               string `json:"accent"`,
	enabled:              bool `json:"enabled"`,
	has_config_dir:       bool `json:"has_config_dir"`,
	has_home_path:        bool `json:"has_home_path"`,
	has_shadow_home_path: bool `json:"has_shadow_home_path"`,
	has_binary:           bool `json:"has_binary"`,
	env_count:            int `json:"env_count"`,
	args_count:           int `json:"args_count"`,
	custom_models_count:  int `json:"custom_models_count"`,
	state:                string `json:"state"`,
	created_at:           i64 `json:"created_at"`,
	updated_at:           i64 `json:"updated_at"`,
}
Provider_Profiles_Report_Wire :: struct {
	type:     string `json:"type"`,
	ok:       bool `json:"ok"`,
	error:    string `json:"error"`,
	profiles: []Provider_Profile_Report_Entry `json:"profiles"`,
}

// The hub receives metadata only: no values, paths, env names or arguments.
profile_report_json :: proc(allocator := context.allocator) -> string {
	sync.mutex_lock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	sync.mutex_unlock(&g_profile_store_mu)
	entries := make([dynamic]Provider_Profile_Report_Entry, context.temp_allocator)
	for &rec in records {
		state := "ok"
		if rec.profile_id != rec.provider && profile_catalog_has(rec.profile_id) do state = "slug_clash"
		c := &rec.config
		append(
			&entries,
			Provider_Profile_Report_Entry {
				profile_id = rec.profile_id,
				provider = rec.provider,
				label_enc = rec.label_enc,
				accent = rec.accent,
				enabled = rec.enabled,
				has_config_dir = c.config_dir != "",
				has_home_path = c.home_path != "",
				has_shadow_home_path = c.shadow_home_path != "",
				has_binary = c.binary_path != "",
				env_count = len(rec.environment),
				args_count = len(profile_tokenize_args(c.launch_args)),
				custom_models_count = len(c.custom_models),
				state = state,
				created_at = rec.created_at,
				updated_at = rec.updated_at,
			},
		)
	}
	err: Profile_Error = .None if ok else .Store_Unavailable
	data, merr := json.marshal(
		Provider_Profiles_Report_Wire {
			type = "provider_profiles_report",
			ok = ok,
			error = profile_error_code(err),
			profiles = entries[:],
		},
		allocator = allocator,
	)
	if merr != nil do return strings.clone(`{"type":"provider_profiles_report","ok":false,"error":"profile_store_unavailable","profiles":[]}`, allocator)
	return string(data)
}
