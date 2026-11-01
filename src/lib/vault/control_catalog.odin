package vault

import "core:encoding/json"
import "core:strings"

CONTROL_FIELDS_AGENT := [?]string{"agent_id","name","slug","template_id","instructions","instructions_error","state","permission_mode","created_at","updated_at","revision","supports"}
CONTROL_TEXT_AGENT := [?]string{"name","slug","instructions"}
CONTROL_FIELDS_INSTANCE := [?]string{"agent_instance_id","agent_id","bridge_id","display_name","provider","provider_profile","model","runtime_status","startup_status","activity_status","project_id","chain_id","current_task_id","current_task_role","revision","configuration_revision","permission_mode","created_at","updated_at","last_seen_at"}
CONTROL_TEXT_INSTANCE := [?]string{"display_name"}
CONTROL_FIELDS_BRIDGE := [?]string{"bridge_id","label","status","machine_os","machine_arch","version","plan_disabled","enrollment_pending","eligible","created_at","last_seen_at"}
CONTROL_TEXT_BRIDGE := [?]string{"label"}
CONTROL_FIELDS_PROVIDER := [?]string{"bridge_id","provider","provider_profile","display_name","label","enabled","profile_state","detection_state","models_state","models_source","models_checked_at","eligible","models","models_next_cursor"}
CONTROL_TEXT_PROVIDER := [?]string{"display_name","label"}

control_catalog_kind :: proc(kind:string)->(Control_Record_Kind,bool) {switch kind {case "agent":return .Agent,true;case "instance":return .Instance,true;case "bridge":return .Bridge,true;case "provider":return .Provider,true;case "artifact":return .Artifact,true;case "memory":return .Memory,true;case "project":return .Project,true;case "issue":return .Issue,true};return {},false}
control_catalog_tool_kind :: proc(tool:string)->string {switch tool {case "agents.list","agents.get":return "agent";case "instances.list","instances.get":return "instance";case "bridges.list":return "bridge";case "providers.list":return "provider";case "artifacts.list","artifacts.get":return "artifact";case "memories.list","memories.get":return "memory";case "projects.list","projects.get":return "project";case "issues.list","issues.get":return "issue"};return ""}
control_catalog_data_ok :: proc(tool:string,data:Control_Data)->bool {
	kind:=control_catalog_tool_kind(tool)
	if data.records_kind!=kind do return false
	if kind=="" do return len(data.records)==0
	return data.chain==nil && len(data.chains)==0 && len(data.tasks)==0 && len(data.comments)==0 && data.comments_next_cursor==""
}

control_seal_agent_fields :: proc(kr:^Vault_Keyring,fields:json.Object)->(string,bool) {
	if kr==nil || !keyring_validate(kr) do return "",false
	out:=make(json.Object,context.temp_allocator)
	for key,value in fields {
		limit:=500;if key=="instructions" do limit=65536
		if key!="name" && key!="slug" && key!="instructions" do return "",false
		text,typed:=value.(json.String);if !typed || len(text)>limit do return "",false
		if key!="instructions" && strings.trim_space(string(text))=="" do return "",false
		token,ok:=seal_string(string(text),kr,context.temp_allocator);if !ok do return "",false
		out[key]=json.String(token)
	}
	encoded,err:=json.marshal(out,allocator=context.temp_allocator)
	return string(encoded),err==nil
}
control_catalog_wipe :: proc(data:Control_Data) {for row in data.records do control_wipe_value(row)}
