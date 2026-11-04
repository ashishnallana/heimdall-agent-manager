package content

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"

// Native bounded variants preserve metadata-only update and hard-delete
// semantics without loading an arbitrary-sized stored binary into memory.
// Text reads stay at 128 KiB (MCP callers pass that); only an MCP html-bundle
// download may read up to the armored 15 MiB artifact budget.
ARTIFACT_BOUNDED_READ_MAX :: 128*1024
ARTIFACT_BOUNDED_BUNDLE_READ_MAX :: domain.VAULT_MAX_TOKEN_HEADER_LEN+4*((contracts.ARTIFACT_MAX_CONTENT_BYTES+domain.VAULT_HEADER_BYTES+2)/3)
get_artifact_bounded :: proc(s:^Content_Service,auth:contracts.Auth_Context,id:string,cap:int)->(domain.Artifact,int,bool,domain.Domain_Error) {
	owner,ok,err:=ownership.owner_from_auth(auth);if !ok do return {},0,false,err
	if s==nil || s.content==nil || s.content.get_artifact_bounded==nil || cap<0 || cap>ARTIFACT_BOUNDED_BUNDLE_READ_MAX do return {},0,false,domain.domain_error(.Internal_Error,"bounded artifact repository not configured")
	return s.content.get_artifact_bounded(s.content.ctx,id,owner,cap)
}
update_artifact_bounded :: proc(s:^Content_Service,auth:contracts.Auth_Context,id,name,description:string)->(domain.Artifact,bool,domain.Domain_Error) {
	a,_,ok,err:=get_artifact_bounded(s,auth,id,0);if !ok do return {},false,err
	if s.content.update_artifact_metadata==nil do return {},false,domain.domain_error(.Internal_Error,"artifact metadata repository not configured")
	ok,err=s.content.update_artifact_metadata(s.content.ctx,id,a.owner_user_id,name,description,platform.clock_now(s.clock));if !ok || err.code!=.None do return {},false,err
	row,_,found,e:=get_artifact_bounded(s,auth,id,0);return row,found,e
}
delete_artifact_bounded :: proc(s:^Content_Service,auth:contracts.Auth_Context,id:string)->(bool,domain.Domain_Error) {
	a,_,ok,err:=get_artifact_bounded(s,auth,id,0);if !ok do return false,err
	return iface.content_delete_artifact(s.content,id,a.owner_user_id)
}
