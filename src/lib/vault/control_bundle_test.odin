#+feature dynamic-literals
package vault

import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import hb "odin_test:lib/html_bundle"

@(test)
test_control_seal_resource_bundle_is_byte_exact_and_validated :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	v:struct {now_ms:i64,keyring_hex,device_id,bridge_device_id:string,entries:[]struct {job:Control_Job,result:string}}
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_artifacts_worker_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	bytes:=make([]byte,len(v.keyring_hex)/2);if !testing.expect(t,hex_decode_into(bytes,v.keyring_hex)) do return
	kr,parsed:=keyring_parse(bytes,v.entries[0].job.owner);if !testing.expect(t,parsed) do return
	defer keyring_wipe(&kr)
	png:=[]byte{0x89,'P','N','G',0x00,0xff,0x80}
	png64,_:=base64.encode(png)
	input:=json.Object{"index.html"=json.Object{"text"=json.String("<p>hi</p>")},"logo.png"=json.Object{"base64"=json.String(png64)}}
	bundle,err:=hb.html_bundle_from_entry_files("index.html",input);if !testing.expect_value(t,err,"") do return
	archive64,_:=base64.encode(bundle.zip)
	out,ok:=control_seal_resource_fields(&kr,"artifacts.create",json.Object{"name"=json.String("site"),"content_base64"=json.String(archive64)})
	if !testing.expect(t,ok) do return
	value,_:=json.parse_string(out,parse_integers=true);obj,_:=value.(json.Object)
	token,typed:=obj["content_base64"].(json.String);if !testing.expect(t,typed) do return
	plain,status:=open(string(token),&kr)
	testing.expect(t,status==.Ok && plain==string(bundle.zip))
	// Rejections: not a bundle, non-canonical base64, both content kinds, wrong tool.
	not_bundle,_:=base64.encode([]byte{1,2,3,4})
	for fields in ([]json.Object{
		json.Object{"name"=json.String("x"),"content_base64"=json.String(not_bundle)},
		json.Object{"name"=json.String("x"),"content_base64"=json.String("eB==")},
		json.Object{"name"=json.String("x"),"content_base64"=json.String(archive64),"content"=json.String("x")},
		json.Object{"name"=json.String("x"),"content_base64"=json.String("")},
	}) {_,rejected:=control_seal_resource_fields(&kr,"artifacts.create",fields);testing.expect(t,!rejected)}
	_,rejected:=control_seal_resource_fields(&kr,"artifacts.update",json.Object{"content_base64"=json.String(archive64)});testing.expect(t,!rejected)
	// Payload bound is artifact-specific.
	testing.expect_value(t,control_job_payload_max("seal_resource","artifacts.create"),CONTROL_JOB_ARTIFACT_PAYLOAD_MAX)
	testing.expect_value(t,control_job_payload_max("seal_resource","memories.create"),4*1024*1024)
	// Bundle download (artifacts.get) is the only read allowed the artifact bound.
	testing.expect_value(t,control_job_payload_max("read","artifacts.get"),CONTROL_JOB_ARTIFACT_PAYLOAD_MAX)
	testing.expect_value(t,control_job_payload_max("read","artifacts.list"),4*1024*1024)
	testing.expect_value(t,control_job_payload_max("read","memories.get"),4*1024*1024)
	// Download: stored token -> exact archive bytes as canonical base64.
	stored,sealed_ok:=seal_string(string(bundle.zip),&kr,context.temp_allocator);testing.expect(t,sealed_ok)
	record:=json.Object{"owner_user_id"=json.String(keyring_user_id(&kr)),"artifact_id"=json.String("art_b"),"kind"=json.String("html-bundle"),"mime"=json.String("application/zip"),"content_base64"=json.String(stored)}
	opened,opened_ok:=control_record_json(&kr,.Artifact,record);testing.expect(t,opened_ok)
	testing.expect(t,strings.contains(opened,archive64) && !strings.contains(opened,"vault:v2:"),"download returns the exact archive as base64")
	testing.expect(t,control_artifact_base64_shape_ok(archive64))
	for bad in ([]string{"","abc","ab=c","a b=","%%%%"}) do testing.expect(t,!control_artifact_base64_shape_ok(bad))
	for bad in ([]json.Object{
		json.Object{"owner_user_id"=record["owner_user_id"],"kind"=json.String("markdown"),"content_base64"=json.String(stored)},
		json.Object{"owner_user_id"=record["owner_user_id"],"kind"=json.String("html-bundle"),"content_base64"=json.String(archive64)},
		json.Object{"owner_user_id"=record["owner_user_id"],"kind"=json.String("html-bundle"),"content_base64"=json.String(stored),"content"=json.String("x"),"mime"=json.String("text/plain")},
	}) {_,ok:=control_record_json(&kr,.Artifact,bad);testing.expect(t,!ok)}
	not_zip,_:=seal_string("not a zip",&kr,context.temp_allocator)
	_,not_zip_ok:=control_record_json(&kr,.Artifact,json.Object{"owner_user_id"=record["owner_user_id"],"kind"=json.String("html-bundle"),"content_base64"=json.String(not_zip)});testing.expect(t,!not_zip_ok)
	testing.expect(t,CONTROL_ARTIFACT_BUNDLE_BASE64_MAX>=hb.HTML_BUNDLE_MAX_ARCHIVE/3*4)
}
