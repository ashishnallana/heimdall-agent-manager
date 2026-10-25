package user
import "core:encoding/json"
import "core:sync"
import "core:strings"
import contracts "odin_test:contracts"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Conversation_Launch_Preferences :: struct {
 agent_id, project_id, bridge_id: string,
 favorite_agent_ids, pinned_agent_ids: []string,
}
launch_preferences_read :: proc(service: ^User_Service, owner: string) -> (Conversation_Launch_Preferences, domain.Domain_Error) {
 payload, err := iface.launch_preferences_get(service.users, owner)
 if err.code != .None do return {}, err
 defer delete(payload)
 prefs: Conversation_Launch_Preferences
 if json.unmarshal_string(payload, &prefs, .JSON, context.temp_allocator) != nil do return {}, domain.domain_error(.Internal_Error, "invalid persisted launch preferences")
 agents, list_err := iface.agent_list_by_owner(service.agents, domain.User_ID(owner), 200, "")
 if list_err.code != .None do return {}, list_err
 defer { for &agent in agents do launch_agent_destroy(&agent); delete(agents) }
 favorites := make([dynamic]string, 0, len(prefs.favorite_agent_ids)+2, context.temp_allocator)
 pinned := make([dynamic]string, context.temp_allocator)
 for id in prefs.pinned_agent_ids { append(&pinned, id); append(&favorites, id) }
 // Only exact seeded identities are pinned; user-created agents using a similar
 // template remain removable. Provisioning reserves these canonical slugs.
 for agent in agents {
  if agent.slug == COORDINATOR_AGENT_SLUG || agent.slug == SOLOIST_AGENT_SLUG {
   id := strings.clone(agent.agent_id, context.temp_allocator)
   known := false; for pinned_id in pinned { if pinned_id == id { known = true; break } }
   if !known { append(&pinned, id); append(&favorites, id) }
  }
 }
 for id in prefs.favorite_agent_ids {
  duplicate := false; for existing in favorites { if existing == id { duplicate = true; break } }
  if !duplicate do append(&favorites, id)
 }
 prefs.favorite_agent_ids = favorites[:]; prefs.pinned_agent_ids = pinned[:]
 return prefs, {}
}
get_launch_preferences :: proc(service: ^User_Service, auth: contracts.Auth_Context) -> (Conversation_Launch_Preferences, domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return {}, domain.domain_error(.Forbidden, "user authentication is required")
 return launch_preferences_read(service, auth.user_id)
}
launch_preferences_write :: proc(service: ^User_Service, owner: string, prefs: Conversation_Launch_Preferences) -> (bool, domain.Domain_Error) {
 payload, err := json.marshal(prefs, allocator = context.temp_allocator)
 if err != nil do return false, domain.domain_error(.Internal_Error, "failed preference encoding")
 return iface.launch_preferences_save(service.users, owner, string(payload))
}
set_launch_selection :: proc(service: ^User_Service, auth: contracts.Auth_Context, field, value: string) -> (Conversation_Launch_Preferences, bool, domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return {}, false, domain.domain_error(.Forbidden, "user authentication is required")
 lock_tok := dbt.timed_lock(&service.launch_preferences_mutex, .Launch_Prefs); defer dbt.timed_unlock(&service.launch_preferences_mutex, .Launch_Prefs, lock_tok)
 prefs, err := launch_preferences_read(service, auth.user_id)
 if err.code != .None do return {}, false, err
 switch field {
 case "agent_id":
  if value != "" {
   favorite := false; for id in prefs.favorite_agent_ids { if id == value { favorite = true; break } }
   if !favorite do return {}, false, domain.domain_error(.Validation_Failed, "select an agent from favorites")
   agent, found, get_err := iface.agent_get(service.agents, value)
   if !found do return {}, false, get_err
   defer launch_agent_destroy(&agent)
   if string(agent.owner_user_id) != auth.user_id || agent.state != .Active do return {}, false, domain.domain_error(.Not_Found, "active agent not found")
  }
  prefs.agent_id = value
 case "project_id":
  if value != "" {
   project, found, get_err := iface.project_get(service.projects, domain.Project_ID(value))
   if !found do return {}, false, get_err
   if string(project.owner_user_id) != auth.user_id || project.state != .Active do return {}, false, domain.domain_error(.Not_Found, "active project not found")
  }
  prefs.project_id = value
 case "bridge_id":
  if value != "" {
   bridge, found, get_err := iface.bridge_get_bridge(service.bridges, value)
   if !found do return {}, false, get_err
   defer domain.bridge_destroy(&bridge)
   if string(bridge.owner_user_id) != auth.user_id || bridge.status == .Revoked do return {}, false, domain.domain_error(.Not_Found, "bridge not found")
  }
  prefs.bridge_id = value
 case: return {}, false, domain.domain_error(.Validation_Failed, "unknown launch selection field")
 }
 saved, save_err := launch_preferences_write(service, auth.user_id, prefs)
 return prefs, saved, save_err
}
set_agent_favorite :: proc(service: ^User_Service, auth: contracts.Auth_Context, agent_id: string, favorite: bool) -> (Conversation_Launch_Preferences, bool, domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return {}, false, domain.domain_error(.Forbidden, "user authentication is required")
 lock_tok := dbt.timed_lock(&service.launch_preferences_mutex, .Launch_Prefs); defer dbt.timed_unlock(&service.launch_preferences_mutex, .Launch_Prefs, lock_tok)
 return set_agent_favorite_locked(service, auth, agent_id, favorite)
}

MAX_FAVORITE_AGENTS :: 6
set_agent_favorite_locked :: proc(service: ^User_Service, auth: contracts.Auth_Context, agent_id: string, favorite: bool) -> (Conversation_Launch_Preferences, bool, domain.Domain_Error) {
 agent, found, err := iface.agent_get(service.agents, agent_id)
 if !found do return {}, false, err
 defer launch_agent_destroy(&agent)
 if string(agent.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Not_Found, "agent not found")
 if !favorite && (agent.slug == COORDINATOR_AGENT_SLUG || agent.slug == SOLOIST_AGENT_SLUG) do return {}, false, domain.domain_error(.Conflict, "Coordinator and Soloist are permanent favorites")
 if favorite && agent.state != .Active do return {}, false, domain.domain_error(.Conflict, "archived agents cannot be added to favorites")
 prefs, read_err := launch_preferences_read(service, auth.user_id)
 if read_err.code != .None do return {}, false, read_err
 already_favorite := false; for id in prefs.favorite_agent_ids { if id == agent_id { already_favorite = true; break } }
 if favorite && !already_favorite && len(prefs.favorite_agent_ids) >= MAX_FAVORITE_AGENTS do return {}, false, domain.domain_error(.Conflict, "You can have up to 6 favorite agents. Remove a favorite before adding another.")
 if !favorite { for id in prefs.pinned_agent_ids { if id == agent_id do return {}, false, domain.domain_error(.Conflict, "Coordinator and Soloist are permanent favorites") } }
 ids := make([dynamic]string, context.temp_allocator)
 for id in prefs.favorite_agent_ids { if id != agent_id do append(&ids, id) }
 if favorite do append(&ids, strings.clone(agent_id, context.temp_allocator))
 prefs.favorite_agent_ids = ids[:]
 if !favorite && prefs.agent_id == agent_id do prefs.agent_id = ""
 saved, save_err := launch_preferences_write(service, auth.user_id, prefs)
 return prefs, saved, save_err
}

launch_agent_destroy :: proc(agent: ^domain.Agent) { delete(agent.agent_id); delete(string(agent.owner_user_id)); delete(agent.name); delete(agent.slug); delete(agent.template_id); delete(agent.instructions); delete(agent.created_at); delete(agent.updated_at) }
