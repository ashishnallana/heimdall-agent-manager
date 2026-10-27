package provider

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Apply a bridge's successful snapshot to an owned catalog entry. Successful empty
// lists are authoritative. No clock/TTL or executable/config change triggers a probe.
effective_model_observation :: proc(repo: ^iface.Provider_Repository, bridge_id: string, entry: ^domain.Provider_Catalog_Entry) -> (domain.Bridge_Provider_Models, domain.Domain_Error) {
	observations, err := iface.bridge_provider_models_list(repo, bridge_id)
	if err.code != .None do return {}, err
	defer domain.bridge_provider_models_list_destroy(observations)
	for &v in observations {
		if v.provider != entry.provider do continue
		if v.has_snapshot {
			models: []Discovered_Model
			if json.unmarshal_string(v.models_json, &models, allocator=context.temp_allocator) != nil do return {}, domain.domain_error(.Internal_Error,"stored model snapshot is invalid")
			for model in entry.models do domain.provider_model_destroy(model)
			delete(entry.models)
			entry.models = make([dynamic]domain.Provider_Model)
			for m, i in models {
				append(&entry.models, domain.Provider_Model{provider=strings.clone(entry.provider),model_id=strings.clone(m.model_id),label=strings.clone(m.label),state=strings.clone("active"),rank=i,resolved_model=strings.clone(m.resolved_model)})
			}
		}
		out := v
		v = {} // transfer ownership
		return out, {}
	}
	return {}, {}
}
apply_effective_models :: proc(repo: ^iface.Provider_Repository, bridge_id: string, entry: ^domain.Provider_Catalog_Entry) -> domain.Domain_Error {
	observation, err := effective_model_observation(repo,bridge_id,entry)
	domain.bridge_provider_models_destroy(observation)
	return err
}
Discovered_Model :: struct {
	model_id: string `json:"model_id"`,
	label: string `json:"label"`,
	resolved_model: string `json:"resolved_model"`,
}
Model_Discovery_Item :: struct {
	provider: string `json:"provider"`,
	binary_path: string `json:"binary_path"`,
	version_text: string `json:"version_text"`,
	models: []Discovered_Model `json:"models"`,
	has_snapshot: bool `json:"has_snapshot"`,
	models_source: string `json:"models_source"`,
	models_checked_at: string `json:"models_checked_at"`,
	models_attempted_at: string `json:"models_attempted_at"`,
	models_state: string `json:"models_state"`,
}
model_id_valid :: proc(id: string) -> bool {
	if len(id)==0 || len(id)>256 || id[0]=='-' do return false
	for c in transmute([]u8)id do if c<=32 || c==127 do return false
	return true
}
model_state_valid :: proc(state: string) -> bool {
	switch state {
	case "success","error","unsupported","absent","busy","timeout","output_limit","invalid_response","authentication_required","page_limit": return true
	}
	return false
}
// Validate the complete report before writing any entry. Only the explicit
// request's authoritative present+enabled filter is allowed to contribute.
apply_model_discovery_report :: proc(service: ^Provider_Service, bridge_id: string, allowed: []string, items: []Model_Discovery_Item) -> domain.Domain_Error {
	if len(items)!=len(allowed) do return domain.domain_error(.Validation_Failed,"model report does not match requested providers")
	for item, i in items {
		permitted := false
		for p in allowed do if p==item.provider do permitted=true
		if !permitted do return domain.domain_error(.Forbidden,"model report contains an unrequested provider")
		for j in 0..<i do if items[j].provider==item.provider do return domain.domain_error(.Validation_Failed,"duplicate model provider")
		if item.models_attempted_at=="" || len(item.models_attempted_at)>64 || len(item.models_checked_at)>64 || len(item.models_source)>64 || !model_state_valid(item.models_state) || len(item.models)>512 do return domain.domain_error(.Validation_Failed,"invalid model outcome")
		if (item.models_state=="success" && !item.has_snapshot) || (item.has_snapshot && (item.models_source=="" || item.models_checked_at=="")) do return domain.domain_error(.Validation_Failed,"incomplete model snapshot")
		encoded, encode_err := json.marshal(item.models, allocator=context.temp_allocator)
		if encode_err!=nil || len(encoded)>128*1024 do return domain.domain_error(.Validation_Failed,"model snapshot exceeds limit")
		for m, j in item.models {
			if !model_id_valid(m.model_id) || len(m.label)>512 || len(m.resolved_model)>256 do return domain.domain_error(.Validation_Failed,"invalid discovered model")
			for k in 0..<j do if item.models[k].model_id==m.model_id do return domain.domain_error(.Validation_Failed,"duplicate model ID")
		}
	}
	for item in items {
		encoded, encode_err := json.marshal(item.models, allocator=context.temp_allocator)
		if encode_err!=nil || len(encoded)>128*1024 do return domain.domain_error(.Validation_Failed,"model snapshot exceeds limit")
		snapshot := item.has_snapshot
		v := domain.Bridge_Provider_Models{
			bridge_id=bridge_id,provider=item.provider,binary_path=item.binary_path if snapshot else "",version_text=item.version_text if snapshot else "",
			has_snapshot=snapshot,models_json=string(encoded) if snapshot else "[]",
			models_source=item.models_source if snapshot else "",models_checked_at=item.models_checked_at if snapshot else "",
			models_attempted_at=item.models_attempted_at,models_state=item.models_state,
		}
		if err := iface.bridge_provider_models_upsert(service.repo,v); err.code!=.None do return err
	}
	return {}
}

// Pure selection over the authoritative view, shared by the explicit API stage.
model_discovery_providers :: proc(views: []Bridge_Provider_View, allocator := context.allocator) -> [dynamic]string {
	out := make([dynamic]string,0,len(views),allocator)
	for view in views do if view.enabled && view.detection_state=="present" && view.catalog.state=="active" do append(&out,strings.clone(view.catalog.provider,allocator))
	return out
}
