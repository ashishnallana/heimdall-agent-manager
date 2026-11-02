package provider

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

profile_id_valid :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 32 || id[0] < 'a' || id[0] > 'z' do return false
	for c in transmute([]u8)id do if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') do return false
	return true
}
list_profiles :: proc(
	repo: ^iface.Provider_Repository,
	bridge_id: string,
) -> (
	[dynamic]domain.Bridge_Provider_Profile,
	domain.Domain_Error,
) {
	if repo == nil do return nil, domain.domain_error(.Internal_Error, "profile repository unavailable")
	if repo.list_profiles == nil do return make([dynamic]domain.Bridge_Provider_Profile), {}
	return repo.list_profiles(repo.ctx, bridge_id)
}
profile_selection_error :: proc(cause: string) -> domain.Domain_Error {
	e := domain.domain_error(.Provider_Unavailable, cause)
	e.cause = cause
	return e
}
validate_profile :: proc(
	repo: ^iface.Provider_Repository,
	bridge_id, provider, profile_id: string,
) -> domain.Domain_Error {
	id := domain.profile_effective_id(provider, profile_id)
	if !profile_id_valid(id) do return profile_selection_error("profile_unknown")
	profiles, err := list_profiles(repo, bridge_id)
	if err.code != .None do return err
	defer domain.bridge_provider_profiles_destroy(profiles)
	for p in profiles {
		if p.profile_id != id do continue
		if p.provider != provider && id == provider do return profile_selection_error("profile_slug_clash")
		if p.provider != provider || p.state == "missing" do return profile_selection_error("profile_unknown")
		if !p.enabled do return profile_selection_error("profile_disabled")
		// slug_clash is the custom profile retaining its existing ID; only the
		// conflicting new driver's default is unavailable.
		return {}
	}
	if id != provider do return profile_selection_error("profile_unknown")
	return {}
}

// Decode into this typed allowlist; additional private fields are never copied
// to a repository or durable event. Validate the entire report before any write.
apply_profiles_report :: proc(
	service: ^Provider_Service,
	bridge_id: string,
	profiles: []domain.Bridge_Provider_Profile,
) -> domain.Domain_Error {
	if len(profiles) > 256 do return domain.domain_error(.Validation_Failed, "too many provider profiles")
	catalog, err := iface.provider_catalog_list(service.repo)
	if err.code != .None do return err
	defer domain.provider_catalog_destroy(catalog)
	previous, perr := list_profiles(service.repo, bridge_id)
	if perr.code != .None do return perr
	defer domain.bridge_provider_profiles_destroy(previous)
	for p, i in profiles {
		if !profile_id_valid(p.profile_id) || len(p.label_enc) > 8192 || (p.label_enc != "" && !strings.has_prefix(p.label_enc, "vault:v2:")) || len(p.accent) > 32 || p.env_count < 0 || p.env_count > 256 || p.args_count < 0 || p.args_count > 32 || p.custom_models_count < 0 || p.custom_models_count > 256 || p.created_at < 0 || p.updated_at < 0 || (p.state != "ok" && p.state != "slug_clash") do return domain.domain_error(.Validation_Failed, "invalid profile metadata")
		for j in 0 ..< i do if profiles[j].profile_id == p.profile_id do return domain.domain_error(.Validation_Failed, "duplicate profile ID")
		found, reserved := false, false
		for e in catalog {if e.provider == p.provider do found = true; if e.provider == p.profile_id && p.provider != p.profile_id do reserved = true}
		if !found do return domain.domain_error(.Validation_Failed, "unknown profile provider")
		if reserved {
			existing := false
			for e in previous do if e.profile_id == p.profile_id && e.provider == p.provider do existing = true
			// A first report after a Hub upgrade may already carry a catalog clash.
			// The bridge enforces namespace ownership when profiles are authored.
			if !existing && p.state != "slug_clash" do return domain.domain_error(.Validation_Failed, "profile_slug_clash")
		}
	}
	values := make([dynamic]domain.Bridge_Provider_Profile, context.temp_allocator)
	append(&values, ..profiles)
	// Bridge reports only stored overrides; catalog defaults are implicit. Reset
	// removes an override, so absent defaults must remain usable instead of missing.
	for e in catalog {
		occupied := false
		for p in profiles do if p.profile_id == e.provider do occupied = true
		if !occupied do append(&values, domain.Bridge_Provider_Profile{profile_id = e.provider, provider = e.provider, enabled = true, state = "ok"})
	}
	if service.repo.reconcile_profiles == nil do return domain.domain_error(.Internal_Error, "profile reconciliation unavailable")
	return service.repo.reconcile_profiles(service.repo.ctx, bridge_id, values[:])
}

// Reports for a disabled profile are valid observations, even though launching
// it is forbidden. The driver binding must still match.
validate_report_profile :: proc(
	repo: ^iface.Provider_Repository,
	bridge_id, provider, profile_id: string,
) -> domain.Domain_Error {
	e := validate_profile(repo, bridge_id, provider, profile_id)
	if e.cause == "profile_disabled" do return {}
	return e
}
