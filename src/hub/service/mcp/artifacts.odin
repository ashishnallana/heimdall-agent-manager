#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import content "odin_test:hub/service/content"
import vault "odin_test:lib/vault"

resource_artifact_mime :: proc(content_type,mime:string)->string {
	value:=mime;if value=="" do value=content_type
	if i:=strings.index(value,";");i>=0 do value=value[:i]
	return strings.to_lower(strings.trim_space(value),context.temp_allocator)
}
resource_artifact_get :: proc(s:^Control_Service,owner,id:string,detail:bool)->(json.Object,string,string) {
	context.allocator=context.temp_allocator
	cap:=0;if detail do cap=128*1024
	a,stored,found,err:=content.get_artifact_bounded(s.content,control_auth(owner),id,cap)
	if !found || err.code!=.None {if err.code==.Validation_Failed do return nil,"","result_too_large";if err.code==.Internal_Error do return nil,"","request_failed";return nil,"","not_found"}
	// Content cannot be replaced by the native lifecycle. Revision deliberately
	// binds metadata/associations and stored length, not a public plaintext hash.
	metadata:=a;metadata.content=""
	revision:=resource_digest(struct {artifact:domain.Artifact,stored_bytes:int}{metadata,stored})
	row:=json.Object{"owner_user_id"=json.String(a.owner_user_id),"artifact_id"=json.String(a.artifact_id),"name"=json.String(a.name),"description"=json.String(a.description),"kind"=json.String(a.kind),"content_type"=json.String(a.content_type),"mime"=json.String(a.mime),"ext"=json.String(a.ext),"size_bytes"=json.Integer(a.size_bytes),"stored_bytes"=json.Integer(stored),"agent_id"=json.String(a.agent_id),"agent_instance_id"=json.String(a.agent_instance_id),"chain_id"=json.String(a.chain_id),"task_id"=json.String(a.task_id),"project_id"=json.String(a.project_id),"link"=json.String(strings.concatenate({"artifact://",a.artifact_id},context.temp_allocator)),"created_at"=json.String(a.created_at),"updated_at"=json.String(a.updated_at),"revision"=json.String(revision)}
	mime:=resource_artifact_mime(a.content_type,a.mime)
	// Older native CLI uploads declare their textual kind but omit MIME. Honor
	// only those explicit native text declarations; never infer from a path/name.
	if mime=="" {
		switch a.kind {case "markdown":mime="text/markdown";case "text":mime="text/plain";case "json":mime="application/json"}
		if mime!="" do row["content_type"]=json.String(mime)
	}
	if detail && resource_artifact_is_bundle(a.kind,mime) {
		// Complete html-bundle download: the stored vault token is relayed to the
		// decrypting device/hosted keyring under content_base64, which returns the
		// exact archive bytes as canonical base64 (never the text content path).
		if a.blob_ref!="" && stored==0 {row["content_error"]=json.String("content_unavailable")} else if stored>content.ARTIFACT_BOUNDED_BUNDLE_READ_MAX {row["content_error"]=json.String("content_too_large")} else {
			if stored>len(a.content) {
				full,full_stored,full_found,full_err:=content.get_artifact_bounded(s.content,control_auth(owner),id,content.ARTIFACT_BOUNDED_BUNDLE_READ_MAX)
				if !full_found || full_err.code!=.None || full_stored!=stored || len(full.content)!=stored do return nil,"","request_failed"
				a.content=full.content
			}
			if !vault.is_armored(a.content) {row["content_error"]=json.String("content_not_encrypted")} else {row["content_base64"]=json.String(a.content)}
		}
	} else if detail {
		if mime!="text/plain" && mime!="text/markdown" && mime!="application/json" {row["content_error"]=json.String("unsupported_content_type")} else if stored>128*1024 {row["content_error"]=json.String("content_too_large")} else if a.blob_ref!="" && stored==0 {row["content_error"]=json.String("content_unavailable")} else {row["content"]=json.String(a.content)}
	}
	return row,revision,""
}
// html-bundle artifacts as stored by ham-ctl, the UI and MCP entry/files creates.
resource_artifact_is_bundle :: proc(kind,mime:string)->bool {return kind=="html-bundle" && (mime=="application/zip" || mime=="")}
