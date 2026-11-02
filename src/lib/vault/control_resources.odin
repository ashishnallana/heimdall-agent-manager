package vault

import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"
import hb "odin_test:lib/html_bundle"

CONTROL_FIELDS_ARTIFACT := [?]string{"artifact_id","name","description","kind","content_type","mime","ext","size_bytes","stored_bytes","agent_id","agent_instance_id","chain_id","task_id","project_id","link","created_at","updated_at","revision","content","content_error","content_base64"}
CONTROL_TEXT_ARTIFACT := [?]string{"name","description","content"}
// artifacts.create with entry/files: the Hub packs the html-bundle ZIP and relays
// it as canonical base64 under this key; the device decodes, re-validates and seals
// the exact archive bytes (the sealed token is returned under the same key).
CONTROL_SEAL_ARTIFACT_CREATE := [?]string{"name","description","content","content_base64"}
// Payload bound for a seal_resource artifacts.create job: base64 of the 15 MiB
// archive plus 1 MiB for name/description/JSON framing.
CONTROL_ARTIFACT_BUNDLE_BASE64_MAX :: (hb.HTML_BUNDLE_MAX_ARCHIVE + 2) / 3 * 4
// artifacts.get of an html-bundle: the Hub relays the stored vault token under
// content_base64; the decrypting side opens it and returns the exact archive bytes
// as canonical base64. Only the ZIP local-header magic and size are checked: this
// is a byte-exact download of an already-stored artifact, and the viewer
// validates the archive on render.
control_artifact_bundle_open :: proc(kr:^Vault_Keyring,record:json.Object,token:string)->(string,bool) {
	kind,_:=record["kind"].(json.String)
	if string(kind)!="html-bundle" || !is_armored(token) do return "",false
	plain,result:=open(token,kr,context.temp_allocator)
	defer if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain))
	if result!=.Ok || len(plain)<4 || len(plain)>hb.HTML_BUNDLE_MAX_ARCHIVE || plain[:4]!="PK\x03\x04" do return "",false
	encoded,err:=base64.encode(transmute([]byte)plain,allocator=context.temp_allocator)
	if err!=nil do return "",false
	return encoded,true
}
// Shape check for a relayed bundle download: canonical-length standard base64 of
// at most the 15 MiB archive. Full decoding happens at the MCP client.
control_artifact_base64_shape_ok :: proc(text:string)->bool {
	if len(text)<8 || len(text)%4!=0 || len(text)>CONTROL_ARTIFACT_BUNDLE_BASE64_MAX do return false
	for c,i in transmute([]byte)text {
		if c>='A' && c<='Z' || c>='a' && c<='z' || c>='0' && c<='9' || c=='+' || c=='/' do continue
		if c=='=' && i>=len(text)-2 && (i==len(text)-1 || text[len(text)-1]=='=') do continue
		return false
	}
	return true
}
CONTROL_SEAL_ARTIFACT_METADATA := [?]string{"name","description"}

control_artifact_type_ok :: proc(fields:json.Object)->bool {
	value,_:=fields["mime"].(json.String);if value=="" do value,_=fields["content_type"].(json.String)
	text:=string(value);if i:=strings.index(text,";");i>=0 do text=text[:i]
	text=strings.to_lower(strings.trim_space(text),context.temp_allocator)
	return text=="text/plain" || text=="text/markdown" || text=="application/json"
}

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
	case "artifacts.create":return "artifact",CONTROL_SEAL_ARTIFACT_CREATE[:]
	case "artifacts.update":return "artifact",CONTROL_SEAL_ARTIFACT_METADATA[:]
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
	if _,bundle:=fields["content_base64"];bundle {
		if _,both:=fields["content"];both || tool!="artifacts.create" do return "",false
	}
	for key,value in fields {
		if key=="content_base64" {
			// Untrusted input: re-validate the archive before sealing its exact bytes.
			text,typed:=value.(json.String);if !typed || len(text)>CONTROL_ARTIFACT_BUNDLE_BASE64_MAX do return "",false
			archive,decoded:=hb.html_bundle_decode_base64(string(text),context.temp_allocator);if !decoded do return "",false
			defer if len(archive)>0 do crypto.zero_explicit(raw_data(archive),len(archive))
			if len(archive)==0 || len(archive)>hb.HTML_BUNDLE_MAX_ARCHIVE do return "",false
			checked,bundle_err:=hb.html_bundle_from_zip(archive,"",context.temp_allocator)
			if bundle_err!="" || string(checked.zip)!=string(archive) do return "",false
			token,ok:=seal_string(string(archive),kr,context.temp_allocator);if !ok do return "",false
			out[key]=json.String(token);continue
		}
		known:=false;for allowed in keys do if key==allowed do known=true
		text,typed:=value.(json.String);if !known || !typed do return "",false
		cap:=20000;if key=="title" || key=="name" do cap=500;if kind=="memory" && key=="body" do cap=65536
		if kind=="artifact" && key=="content" do cap=65536
		if !utf8.valid_string(string(text)) || strings.contains(string(text),"\x00") || len(text)>cap || (key=="name" || key=="title" || key=="body") && strings.trim_space(string(text))=="" do return "",false
		token,ok:=seal_string(string(text),kr,context.temp_allocator);if !ok do return "",false
		out[key]=json.String(token)
	}
	encoded,err:=json.marshal(out,allocator=context.temp_allocator);return string(encoded),err==nil
}
