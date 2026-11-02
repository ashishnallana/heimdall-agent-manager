package provider

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Provider_Test_Run :: struct {
	profile_id:string,
	run_id,
	owner_user_id,
	bridge_id,
	provider,
	model,
	agent_instance_id,
	state,
	expires_at,
	error: string,
}

Provider_Service :: struct {
	repo:       ^iface.Provider_Repository,
	test_mutex: sync.Mutex,
	extension_mutex: sync.Mutex,
	test_runs:  [dynamic]Provider_Test_Run,
}

Provider_Catalog_Result :: struct {
	providers:    [dynamic]domain.Provider_Catalog_Entry,
	catalog_etag: string,
}

Bridge_Provider_View :: struct {
	profile_id: string,
	profile_state: string,
	label_enc: string,
	accent: string,
	catalog:         domain.Provider_Catalog_Entry,
	models_source, models_checked_at, models_attempted_at, models_state: string,
	models_binary_path, models_version_text: string,
	models_has_snapshot: bool,
	bridge_id:       string,
	binary_path:     string,
	version_text:    string,
	detection_state: string,
	checked_at:      string,
	enabled:         bool,
	extension_state:      string,
	extension_version:    string,
	extension_checked_at: string,
}

bridge_provider_view_destroy :: proc(value: Bridge_Provider_View) {
	delete(value.profile_id); delete(value.profile_state); delete(value.label_enc); delete(value.accent)
	domain.provider_catalog_entry_destroy(value.catalog)
	delete(value.models_source); delete(value.models_checked_at); delete(value.models_attempted_at); delete(value.models_state)
	delete(value.models_binary_path); delete(value.models_version_text)
	delete(value.bridge_id); delete(value.binary_path); delete(value.version_text)
	delete(value.detection_state); delete(value.checked_at)
	delete(value.extension_state); delete(value.extension_version); delete(value.extension_checked_at)
}

bridge_provider_views_destroy :: proc(values: [dynamic]Bridge_Provider_View) {
	for value in values do bridge_provider_view_destroy(value)
	delete(values)
}

new_provider_service :: proc(repo: ^iface.Provider_Repository) -> Provider_Service {
	return Provider_Service {
		repo = repo,
		test_runs = make([dynamic]Provider_Test_Run, runtime.default_allocator()),
	}
}

provider_test_run_clone :: proc(
	run: Provider_Test_Run,
	allocator := context.allocator,
) -> Provider_Test_Run {
	return Provider_Test_Run {
		profile_id=strings.clone(domain.profile_effective_id(run.provider,run.profile_id),allocator),
		run_id = strings.clone(run.run_id, allocator),
		owner_user_id = strings.clone(run.owner_user_id, allocator),
		bridge_id = strings.clone(run.bridge_id, allocator),
		provider = strings.clone(run.provider, allocator),
		model = strings.clone(run.model, allocator),
		agent_instance_id = strings.clone(run.agent_instance_id, allocator),
		state = strings.clone(run.state, allocator),
		expires_at = strings.clone(run.expires_at, allocator),
		error = strings.clone(run.error, allocator),
	}
}

provider_test_run_destroy :: proc(run: ^Provider_Test_Run) {
	if run == nil do return
	delete(run.profile_id)
	delete(
		run.run_id,
	); delete(run.owner_user_id); delete(run.bridge_id); delete(run.provider); delete(run.model); delete(run.agent_instance_id); delete(run.state); delete(run.expires_at); delete(run.error)
	run^ = {}
}

provider_test_register :: proc(
	service: ^Provider_Service,
	run: Provider_Test_Run,
) -> (
	Provider_Test_Run,
	domain.Domain_Error,
) {
	sync.mutex_lock(&service.test_mutex); defer sync.mutex_unlock(&service.test_mutex)
	active_for_owner, active_for_bridge := 0, 0
	for existing in service.test_runs {
		if existing.state == "stopped" || existing.state == "failed" || existing.state == "cancelled" || existing.state == "expired" do continue
		if existing.owner_user_id == run.owner_user_id do active_for_owner += 1
		if existing.bridge_id == run.bridge_id do active_for_bridge += 1
	}
	if active_for_owner >= 3 || active_for_bridge >= 1 do return {}, domain.domain_error(.Conflict, "provider test concurrency limit reached")
	// The registry outlives this HTTP request. Never retain request-arena strings:
	// the background reaper reads these records long after the handler returns.
	append(&service.test_runs, provider_test_run_clone(run, runtime.default_allocator()))
	return provider_test_run_clone(run), {}
}

provider_test_get :: proc(
	service: ^Provider_Service,
	run_id, owner_user_id: string,
) -> (
	Provider_Test_Run,
	bool,
) {
	sync.mutex_lock(&service.test_mutex); defer sync.mutex_unlock(&service.test_mutex)
	for run in service.test_runs {if run.run_id == run_id && run.owner_user_id == owner_user_id do return provider_test_run_clone(run), true}
	return {}, false
}

// provider_test_active_runs returns owned snapshots of every non-terminal test.
// The caller can safely perform slow stop/delete work without holding test_mutex.
provider_test_active_runs :: proc(service: ^Provider_Service) -> [dynamic]Provider_Test_Run {
	out := make([dynamic]Provider_Test_Run)
	if service == nil do return out
	sync.mutex_lock(&service.test_mutex); defer sync.mutex_unlock(&service.test_mutex)
	for run in service.test_runs {
		if run.state == "stopped" || run.state == "failed" || run.state == "cancelled" || run.state == "expired" do continue
		append(&out, provider_test_run_clone(run))
	}
	return out
}

// provider_test_active_runs_for_bridge returns the superseded runs a new test
// must stop first. Ownership is part of the filter so one user's request can
// never terminate another user's ephemeral process, even if bridge ids are
// supplied from an untrusted request path.
provider_test_active_runs_for_bridge :: proc(
	service: ^Provider_Service,
	owner_user_id, bridge_id: string,
) -> [dynamic]Provider_Test_Run {
	out := make([dynamic]Provider_Test_Run)
	if service == nil do return out
	sync.mutex_lock(&service.test_mutex); defer sync.mutex_unlock(&service.test_mutex)
	for run in service.test_runs {
		if run.owner_user_id != owner_user_id || run.bridge_id != bridge_id do continue
		if run.state == "stopped" || run.state == "failed" || run.state == "cancelled" || run.state == "expired" do continue
		append(&out, provider_test_run_clone(run))
	}
	return out
}

provider_test_runs_destroy :: proc(runs: [dynamic]Provider_Test_Run) {
	for &run in runs do provider_test_run_destroy(&run)
	delete(runs)
}

provider_test_set_state :: proc(
	service: ^Provider_Service,
	run_id, owner_user_id, state, error: string,
) -> (
	Provider_Test_Run,
	bool,
) {
	sync.mutex_lock(&service.test_mutex); defer sync.mutex_unlock(&service.test_mutex)
	for &run in service.test_runs {
		if run.run_id != run_id || (owner_user_id != "" && run.owner_user_id != owner_user_id) do continue
		delete(
			run.state,
			runtime.default_allocator(),
		); run.state = strings.clone(state, runtime.default_allocator())
		delete(
			run.error,
			runtime.default_allocator(),
		); run.error = strings.clone(error, runtime.default_allocator())
		return provider_test_run_clone(run), true
	}
	return {}, false
}

provider_test_mark_instance_ready :: proc(service: ^Provider_Service, instance_id: string) {
	sync.mutex_lock(&service.test_mutex); defer sync.mutex_unlock(&service.test_mutex)
	for &run in service.test_runs {
		if run.agent_instance_id == instance_id &&
		   (run.state == "starting" || run.state == "detecting") {
			delete(
				run.state,
				runtime.default_allocator(),
			); run.state = strings.clone("awaiting_validation", runtime.default_allocator())
			return
		}
	}
}

validate_launchable :: proc(
	service: ^Provider_Service,
	bridge_id, provider, model: string,
	profile_id: string = "",
) -> domain.Domain_Error {
	if e:=validate_profile(service.repo,bridge_id,provider,profile_id);e.code!=.None do return e
	entry, found, err := iface.provider_catalog_get(service.repo, provider)
	if err.code != .None do return err
	if !found || entry.state != "active" do return domain.domain_error(.Unprocessable_Entity, "provider is unknown or deprecated")
	defer domain.provider_catalog_entry_destroy(entry)
	if model_err := apply_effective_models(service.repo, bridge_id, &entry,profile_id); model_err.code != .None do return model_err
	model_ok := false
	for candidate in entry.models {if candidate.model_id == model && candidate.state == "active" {model_ok = true; break}}
	if !model_ok do return domain.domain_error(.Unprocessable_Entity, "model is unknown or deprecated for provider")
	views, view_err := list_bridge_providers(service, bridge_id)
	if view_err.code != .None do return view_err
	defer bridge_provider_views_destroy(views)
	for view in views {if view.catalog.provider == provider && view.profile_id==domain.profile_effective_id(provider,profile_id) && view.enabled && view.detection_state == "present" do return {}}
	return domain.domain_error(.Conflict, "provider is not enabled and present on this bridge")
}

list_catalog :: proc(
	service: ^Provider_Service,
) -> (
	Provider_Catalog_Result,
	domain.Domain_Error,
) {
	if service == nil || service.repo == nil do return {}, domain.domain_error(.Internal_Error, "provider service is not configured")
	providers, err := iface.provider_catalog_list(service.repo)
	if err.code != .None do return {}, err
	// The canonical wire body is the source of truth for the catalog version.
	// provider_catalog_meta is retained as migration/audit metadata, but it must
	// never be a second authority capable of taking every authenticated Bridge
	// offline when a catalog migration changes rows without updating its hash.
	body := catalog_body_json(providers)
	defer delete(body)
	etag := catalog_body_etag(body)
	return Provider_Catalog_Result{providers = providers, catalog_etag = etag}, {}
}

catalog_etag :: proc(service: ^Provider_Service) -> (string, domain.Domain_Error) {
	result, err := list_catalog(service)
	if err.code != .None do return "", err
	domain.provider_catalog_destroy(result.providers)
	return result.catalog_etag, {}
}

catalog_body_etag :: proc(body: string) -> string {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, body, buf[:])
	hex_value := hex.encode(buf[:])
	defer delete(hex_value)
	return strings.concatenate({"sha256:", string(hex_value)})
}

write_model_json :: proc(b: ^strings.Builder, model: domain.Provider_Model) {
	strings.write_string(b, "{\"model_id\":\"")
	contracts.write_json_string(b, model.model_id)
	strings.write_string(b, "\",\"label\":\"")
	contracts.write_json_string(b, model.label)
	strings.write_string(b, "\",\"state\":\"")
	contracts.write_json_string(b, model.state)
	strings.write_byte(b, '"')
	if model.resolved_model != "" {
		strings.write_string(b, ",\"resolved_model\":\"")
		contracts.write_json_string(b, model.resolved_model)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '}')
}

write_catalog_entry_json :: proc(b: ^strings.Builder, entry: domain.Provider_Catalog_Entry) {
	strings.write_string(b, "{\"provider\":\""); contracts.write_json_string(b, entry.provider)
	strings.write_string(
		b,
		"\",\"display_name\":\"",
	); contracts.write_json_string(b, entry.display_name)
	strings.write_string(b, "\",\"icon_url\":\""); contracts.write_json_string(b, entry.icon_url)
	strings.write_string(b, "\",\"binary\":\""); contracts.write_json_string(b, entry.binary)
	strings.write_string(b, "\",\"base_args\":"); strings.write_string(b, entry.base_args_json)
	strings.write_string(b, ",\"yolo_args\":"); strings.write_string(b, entry.yolo_args_json)
	strings.write_string(b, ",\"ask_args\":"); strings.write_string(b, entry.ask_args_json if entry.ask_args_json != "" else "[]")
	strings.write_string(b, ",\"model_flag\":\""); contracts.write_json_string(b, entry.model_flag)
	strings.write_string(b, "\",\"prompt_args\":"); strings.write_string(b, entry.prompt_args_json)
	strings.write_string(
		b,
		",\"prompt_delivery\":\"",
	); contracts.write_json_string(b, entry.prompt_delivery)
	strings.write_string(
		b,
		"\",\"starter_prompt\":\"",
	); contracts.write_json_string(b, entry.starter_prompt)
	strings.write_string(
		b,
		"\",\"bootstrap_file\":\"",
	); contracts.write_json_string(b, entry.bootstrap_file)
	strings.write_string(b, "\",\"skill_dir\":\""); contracts.write_json_string(b, entry.skill_dir)
	strings.write_string(
		b,
		"\",\"startup_detection\":",
	); strings.write_string(b, entry.startup_detection_json)
	strings.write_string(
		b,
		",\"activity_detection\":",
	); strings.write_string(b, entry.activity_detection_json)
	// extension is null for a provider without one; a Bridge reports it 'unsupported'.
	strings.write_string(b, ",\"extension\":")
	strings.write_string(b, entry.extension_json if entry.extension_json != "" else "null")
	strings.write_string(b, ",\"state\":\""); contracts.write_json_string(b, entry.state)
	strings.write_string(b, "\",\"models\":[")
	for model, i in entry.models {
		if i > 0 do strings.write_byte(b, ',')
		write_model_json(b, model)
	}
	strings.write_string(b, "]}")
}

// catalog_body_json is the one canonical wire body hashed into catalog_etag and
// replicated to Bridges. Field and row ordering are therefore part of the protocol.
catalog_body_json :: proc(providers: [dynamic]domain.Provider_Catalog_Entry) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"providers\":[")
	for entry, i in providers {
		if i > 0 do strings.write_byte(&b, ',')
		write_catalog_entry_json(&b, entry)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

get_icon :: proc(
	service: ^Provider_Service,
	provider: string,
) -> (
	domain.Provider_Icon,
	bool,
	domain.Domain_Error,
) {
	name := strings.trim_space(provider)
	if name == "" do return {}, false, domain.domain_error(.Validation_Failed, "provider is required")
	icon, found, err := iface.provider_icon_get(service.repo, name)
	if err.code != .None do return {}, false, err
	if !found do return {}, false, domain.domain_error(.Not_Found, "provider icon not found")
	return icon, true, {}
}

list_bridge_providers :: proc(service: ^Provider_Service, bridge_id: string) -> ([dynamic]Bridge_Provider_View,domain.Domain_Error) {
 catalog,err:=iface.provider_catalog_list(service.repo)
 if err.code!=.None do return nil,err
 defer domain.provider_catalog_destroy(catalog)
 profiles,perr:=list_profiles(service.repo,bridge_id)
 if perr.code!=.None do return nil,perr
 defer domain.bridge_provider_profiles_destroy(profiles)
 identities:=make([dynamic]domain.Bridge_Provider_Profile,context.temp_allocator)
 append(&identities,..profiles[:])
 for e in catalog {
  occupied:=false
  for p in profiles do if p.profile_id==e.provider do occupied=true
  if !occupied do append(&identities,domain.Bridge_Provider_Profile{profile_id=e.provider,provider=e.provider,enabled=true,state="ok"})
 }
 statuses,serr:=iface.bridge_provider_status_list(service.repo,bridge_id)
 if serr.code!=.None do return nil,serr
 defer domain.bridge_provider_statuses_destroy(statuses)
 settings,seterr:=iface.bridge_provider_setting_list(service.repo,bridge_id)
 if seterr.code!=.None do return nil,seterr
 defer domain.bridge_provider_settings_destroy(settings)
 views:=make([dynamic]Bridge_Provider_View)
 for p in identities {
  entry,found,eerr:=iface.provider_catalog_get(service.repo,p.provider)
  if eerr.code!=.None { bridge_provider_views_destroy(views);return nil,eerr }
  if !found do continue
  v:=Bridge_Provider_View{catalog=entry,bridge_id=strings.clone(bridge_id),profile_id=strings.clone(p.profile_id),profile_state=strings.clone(p.state),label_enc=strings.clone(p.label_enc),accent=strings.clone(p.accent),enabled=p.enabled && p.profile_id!=p.provider,binary_path=strings.clone(""),version_text=strings.clone(""),detection_state=strings.clone("absent"),checked_at=strings.clone(""),extension_state=strings.clone(""),extension_version=strings.clone(""),extension_checked_at=strings.clone("")}
  for status in statuses {
   if status.provider!=p.provider || domain.profile_effective_id(status.provider,status.profile_id)!=p.profile_id do continue
   delete(v.binary_path);v.binary_path=strings.clone(status.binary_path)
   delete(v.version_text);v.version_text=strings.clone(status.version_text)
   delete(v.detection_state);v.detection_state=strings.clone(status.state)
   delete(v.checked_at);v.checked_at=strings.clone(status.checked_at)
   delete(v.extension_state);v.extension_state=strings.clone(status.extension_state)
   delete(v.extension_version);v.extension_version=strings.clone(status.extension_version)
   delete(v.extension_checked_at);v.extension_checked_at=strings.clone(status.extension_checked_at)
   break
  }
  for setting in settings do if setting.provider==p.provider && domain.profile_effective_id(setting.provider,setting.profile_id)==p.profile_id {v.enabled=setting.enabled;break}
  v.enabled=v.enabled && p.enabled && p.state!="missing"
  observation,oerr:=effective_model_observation(service.repo,bridge_id,&v.catalog,p.profile_id)
  if oerr.code!=.None {bridge_provider_view_destroy(v);bridge_provider_views_destroy(views);return nil,oerr}
  v.models_source=strings.clone(observation.models_source if observation.has_snapshot else "static_fallback")
  v.models_checked_at=strings.clone(observation.models_checked_at)
  v.models_attempted_at=strings.clone(observation.models_attempted_at)
  v.models_state=strings.clone(observation.models_state if observation.models_state!="" else "not_checked")
  v.models_binary_path=strings.clone(observation.binary_path);v.models_version_text=strings.clone(observation.version_text);v.models_has_snapshot=observation.has_snapshot
  domain.bridge_provider_models_destroy(observation)
  append(&views,v)
 }
 return views,{}
}

apply_discovery_report :: proc(
	service: ^Provider_Service,
	bridge_id: string,
	statuses: []domain.Bridge_Provider_Status,
) -> domain.Domain_Error {
	for status in statuses {
		if status.bridge_id != bridge_id do return domain.domain_error(.Forbidden, "discovery report bridge does not match the authenticated connection")
		if status.state != "present" && status.state != "absent" && status.state != "disabled" && status.state != "error" do return domain.domain_error(.Validation_Failed, "provider discovery state must be present or absent")
		if !extension_state_valid(status.extension_state) do return domain.domain_error(.Validation_Failed, "provider extension state must be present, disabled, outdated, absent, error or unsupported")
		entry, found, get_err := iface.provider_catalog_get(service.repo, status.provider)
		if get_err.code != .None do return get_err
		if !found do return domain.domain_error(.Validation_Failed, "discovery report contains an unknown provider")
		has_extension := entry.extension_json != ""
		domain.provider_catalog_entry_destroy(entry)
		stored := status
		if status.profile_id!="" do stored.binary_path=""
		if e:=validate_report_profile(service.repo,bridge_id,status.provider,status.profile_id);e.code!=.None do return e
		// The catalog, not the Bridge, decides whether an extension exists. A report
		// from a Bridge older than REQ-EXT-DET-1 carries no state and stays "".
		if !has_extension && stored.extension_state != "" {
			stored.extension_state = "unsupported"
			stored.extension_version = ""
		} else if has_extension && stored.extension_state == "unsupported" {
			// The Bridge's catalog snapshot predates the descriptor; its claim says
			// nothing about the extension, so record "not measured yet".
			stored.extension_state = ""
			stored.extension_version = ""
		}
		if _, save_err := iface.bridge_provider_status_upsert(service.repo, stored); save_err.code != .None do return save_err
	}
	return {}
}

// "" is accepted for Bridges that predate extension detection (REQ-EXT-DET-1).
extension_state_valid :: proc(state: string) -> bool {
	switch state {
	case "", "present", "disabled", "outdated", "absent", "error", "unsupported":
		return true
	}
	return false
}

set_bridge_provider_enabled :: proc(
	service: ^Provider_Service,
	bridge_id, provider, updated_at: string,
	enabled: bool,
	profile_id: string = "",
) -> (
	domain.Bridge_Provider_Setting,
	bool,
	domain.Domain_Error,
) {
	entry, found, entry_err := iface.provider_catalog_get(service.repo, provider)
	if entry_err.code != .None do return {}, false, entry_err
	if !found do return {}, false, domain.domain_error(.Unprocessable_Entity, "unknown provider")
	defer domain.provider_catalog_entry_destroy(entry)
	if entry.state != "active" do return {}, false, domain.domain_error(.Unprocessable_Entity, "provider is deprecated")
	if enabled {
		statuses, status_err := iface.bridge_provider_status_list(service.repo, bridge_id)
		if status_err.code != .None do return {}, false, status_err
		defer domain.bridge_provider_statuses_destroy(statuses)
		present := false
		for status in statuses {if status.provider == provider && domain.profile_effective_id(provider,status.profile_id)==domain.profile_effective_id(provider,profile_id) &&
			   status.state == "present" {present = true; break}}
		if !present do return {}, false, domain.domain_error(.Conflict, "provider is not present on this bridge")
	}
	setting := domain.Bridge_Provider_Setting {
		profile_id = domain.profile_effective_id(provider,profile_id),
		bridge_id  = bridge_id,
		provider   = provider,
		enabled    = enabled,
		updated_at = updated_at,
	}
	if _, save_err := iface.bridge_provider_setting_upsert(service.repo, setting); save_err.code != .None do return {}, false, save_err
	return setting, true, {}
}
