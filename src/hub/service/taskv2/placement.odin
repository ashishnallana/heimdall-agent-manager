package taskv2

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import provider_service "odin_test:hub/service/provider"

// fleet_model_on_bridge returns the fleet row's provider/model for a bridge,
// honouring a per-bridge override in bridge_models_json.
fleet_model_on_bridge :: proc(fleet: domain.Task_Chain_Fleet, bridge_id: string) -> (string, string) {
	if fleet.bridge_models_json != "" {
		entries: map[string]domain.Fleet_Bridge_Model
		if json.unmarshal((transmute([]u8) fleet.bridge_models_json), &entries, allocator = context.temp_allocator) == nil {
			if selection, found := entries[bridge_id]; found { return selection.provider, selection.model }
		}
	}
	return fleet.provider, fleet.model
}

// resolve_launch_model fills an empty provider/model from the active catalog
// intersected with what the bridge supports. Catalog order is rank then id.
// Explicit selections are preserved: an unavailable selection must fail rather
// than silently launch a different provider or model. Caller owns the strings.
resolve_launch_model :: proc(agent_service: ^agent.Agent_Service, bridge_id, provider, model: string,provider_profile:string = "") -> (string, string) {
	if provider != "" && model != "" do return strings.clone(provider), strings.clone(model)
	if agent_service == nil || agent_service.providers == nil do return strings.clone(provider), strings.clone(model)
	catalog, err := iface.provider_catalog_list(agent_service.providers)
	if err.code != .None do return strings.clone(provider), strings.clone(model)
	defer domain.provider_catalog_destroy(catalog)
	for &entry in catalog {
		if entry.state != "active" || (provider != "" && entry.provider != provider) do continue
		if err := provider_service.apply_effective_models(agent_service.providers,bridge_id,&entry,provider_profile); err.code != .None do continue
		for candidate in entry.models {
			if candidate.state != "active" || (model != "" && candidate.model_id != model) do continue
			_, ok, _ := agent.validate_provider_model_intersection(agent_service, bridge_id, entry.provider, candidate.model_id,provider_profile)
			if ok do return strings.clone(entry.provider), strings.clone(candidate.model_id)
		}
	}
	return strings.clone(provider), strings.clone(model)
}

// A provider override deliberately discards the instance's old model. Empty
// provider/model together retain the catalog-default fleet inheritance rule.
lease_launch_model :: proc(svc: ^Service, placement: Placement, inst: domain.Agent_Instance) -> (string, string) {
	provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model,placement.provider_profile)
	if provider == "" { delete(provider); provider = strings.clone(inst.provider) }
	if model == "" && placement.provider == "" {
		delete(model); model = strings.clone(inst.model)
	}
	return provider, model
}

fleet_profile_on_bridge :: proc(fleet:domain.Task_Chain_Fleet,bridge_id:string) -> string {
 if fleet.bridge_models_json!="" {
  entries:map[string]domain.Fleet_Bridge_Model
  if json.unmarshal_string(fleet.bridge_models_json,&entries,allocator=context.temp_allocator)==nil {
   if selection,found:=entries[bridge_id];found do return domain.profile_effective_id(selection.provider,selection.provider_profile)
  }
 }
 return domain.profile_effective_id(fleet.provider,fleet.provider_profile)
}
