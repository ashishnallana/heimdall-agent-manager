package vault

import "core:encoding/json"
import "core:strings"

CONTROL_FIELDS_MEMORY := [?]string{"memory_id","read_only","title","description","body","evidence","title_error","description_error","body_error","evidence_error","type","status","expires_at","agent_ids","project_ids","bridge_ids","template_ids","proposed_by_instance_id","proposed_in_chain_id","created_at","updated_at","revision"}
CONTROL_TEXT_MEMORY := [?]string{"title","description","body","evidence"}
CONTROL_FIELDS_PROJECT := [?]string{"project_id","name","name_error","slug","description","description_error","repo_url","vcs_kind","default_path","state","created_at","updated_at","revision","bridge_paths"}
CONTROL_TEXT_PROJECT := [?]string{"name","description","slug"}
CONTROL_SEAL_PROJECT := [?]string{"name","description"}
CONTROL_FIELDS_ISSUE := [?]string{"issue_id","title","title_error","description","description_error","description_limit","created_by","status","scope_type","target_id","chain_id","vote_count","comment_count","created_at","updated_at","closed_at","revision","comments","comments_next_cursor"}
CONTROL_TEXT_ISSUE := [?]string{"title","description"}
CONTROL_FIELDS_ISSUE_COMMENT := [?]string{"comment_id","issue_id","author_id","author_name","body","body_error","created_at","updated_at"}
CONTROL_TEXT_ISSUE_COMMENT := [?]string{"author_name","body"}
CONTROL_SEAL_ISSUE_COMMENT := [?]string{"body"}

control_resource_limits :: proc(tool:string)->(kind:string,keys:[]string) {
	switch tool {
	case "memories.create","memories.update":return "memory",CONTROL_TEXT_MEMORY[:]
	case "projects.create","projects.update":return "project",CONTROL_SEAL_PROJECT[:]
	case "issues.create","issues.update":return "issue",CONTROL_TEXT_ISSUE[:]
	case "issues.comment":return "issue_comment",CONTROL_SEAL_ISSUE_COMMENT[:]
	}
	return "",nil
}
control_seal_resource_fields :: proc(kr:^Vault_Keyring,tool:string,fields:json.Object)->(string,bool) {
	kind,keys:=control_resource_limits(tool)
	if kind=="" || kr==nil || !keyring_validate(kr) do return "",false
	out:=make(json.Object,context.temp_allocator)
	for key,value in fields {
		known:=false;for allowed in keys do if key==allowed do known=true
		text,typed:=value.(json.String);if !known || !typed do return "",false
		cap:=20000;if key=="title" || key=="name" do cap=500;if kind=="memory" && key=="body" do cap=65536
		if len(text)>cap || (key=="name" || key=="title" || key=="body") && strings.trim_space(string(text))=="" do return "",false
		token,ok:=seal_string(string(text),kr,context.temp_allocator);if !ok do return "",false
		out[key]=json.String(token)
	}
	encoded,err:=json.marshal(out,allocator=context.temp_allocator);return string(encoded),err==nil
}
