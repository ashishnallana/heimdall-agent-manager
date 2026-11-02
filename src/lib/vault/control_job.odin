package vault

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Control_Data :: struct {
	records_kind:string `json:"records_kind,omitempty"`,
	records:[]json.Object `json:"records,omitempty"`,
	chains:[]json.Object `json:"chains,omitempty"`,
	chain:json.Object `json:"chain,omitempty"`,
	tasks:[]json.Object `json:"tasks,omitempty"`,
	comments:[]json.Object `json:"comments,omitempty"`,
	next_cursor:string `json:"next_cursor,omitempty"`,
	comments_next_cursor:string `json:"comments_next_cursor,omitempty"`,
}
Control_Consent :: struct {
	v:int,
	owner,vault_id,client,resource,scope,grant,family:string,
	revision:i64,
	mode,recipient,recipient_public_key,approver:string,
	directory_version:i64,
	directory_head:string,
	epoch,issued_ms:i64,
	wrap_sha256:string,
}
Control_Job :: struct {
	request_id,generation,owner,resource,grant,head,operation,payload,digest:string,
	revision,deadline_ms:i64,
	epoch:u32,
	consent,signature:string,
	directory:Directory_Verification_Input,
	tool:string `json:"tool,omitempty"`,
}
Control_Reply :: struct {request_id,generation,digest,device_id,result,signature:string,deadline_ms:i64}
control_reply_statement :: proc(job:Control_Job,device_id,result:string)->string {
	// All identifiers and hashes are restricted single-line values.
	return fmt.tprintf("heimdall-mcp-worker-result/v1\n%s\n%s\n%s\n%s\n%s\n%d\n%s\n%s\n%s\n%d\n%s",job.owner,job.resource,job.grant,job.request_id,job.generation,job.revision,job.head,job.digest,device_id,job.deadline_ms,sha256_hex(result))
}
// Artifact-specific bound: only an artifacts.create seal job may carry a packed
// html-bundle (base64 of <=15 MiB + 1 MiB framing); every other job keeps 4 MiB.
CONTROL_JOB_PAYLOAD_MAX :: 4*1024*1024
CONTROL_JOB_ARTIFACT_PAYLOAD_MAX :: CONTROL_ARTIFACT_BUNDLE_BASE64_MAX+1024*1024
control_job_payload_max :: proc(operation,tool:string)->int {
	if operation=="seal_resource" && tool=="artifacts.create" do return CONTROL_JOB_ARTIFACT_PAYLOAD_MAX
	return CONTROL_JOB_PAYLOAD_MAX
}
// Reply bound: a bundle seal returns the armored archive token (~base64 size).
control_reply_max :: proc(operation,tool:string)->int {return control_job_payload_max(operation,tool)}
control_job_digest :: proc(job:Control_Job)->string {
	// Include EVERY authority/operation field and public directory snapshot.
	j:=job;j.digest=""
	encoded,err:=json.marshal(j,allocator=context.temp_allocator)
	if err!=nil do return ""
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	return sha256_hex(string(encoded))
}
control_job_verify :: proc(job:Control_Job,owner,resource,device_id:string,kr:^Vault_Keyring,now:i64,root_pin:^Root_Pin=nil)->bool {
	if job.owner!=owner || job.resource!=resource || job.request_id=="" || !valid_id_value(job.request_id) || job.generation=="" || !valid_id_value(job.generation) || job.deadline_ms<=now || job.deadline_ms>now+5000 || len(job.payload)>control_job_payload_max(job.operation,job.tool) || job.digest!=control_job_digest(job) || (job.operation!="read" && job.operation!="seal" && job.operation!="seal_comment" && job.operation!="seal_task" && job.operation!="seal_agent" && job.operation!="seal_resource") do return false
	c:Control_Consent
	if json.unmarshal_string(job.consent,&c,.JSON,context.temp_allocator)!=nil do return false
	if !control_job_scope_ok(c.scope,job.tool,job.operation) do return false
	canonical,err:=json.marshal(c,allocator=context.temp_allocator)
	if err!=nil || string(canonical)!=job.consent || c.v==0 || c.v!=control_consent_version(c.scope) || c.mode!="device" || c.owner!=owner || c.resource!=resource || c.grant!=job.grant || c.revision!=job.revision || c.client=="" || c.family=="" || c.recipient!="" || c.recipient_public_key!="" || c.wrap_sha256!="" do return false
	d:=job.directory
	if d.owner!=owner || d.head_hash!=job.head || d.current_epoch!=i64(job.epoch) || d.vault_id!=c.vault_id || d.pin_seq!=c.directory_version || d.pin_hash!=c.directory_head do return false
	verified,ok:=directory_verify(d)
	if !ok || !directory_verify_keyring(&verified,kr) do return false
	if root_pin!=nil {
		root:=verified.ever_approved[verified.root_device_id]
		pin,valid:=root_pin_from_hex(verified.root_device_id,root.sign_alg,verified.root_public_key)
		if !valid || !root_pin_equal(root_pin,&pin) do return false
	}
	me,trusted:=verified.trusted[device_id]
	if !trusted || (me.kind!="bridge" && !kind_policy(device_kind_from_id(me.kind)).receives_wrap) do return false
	approver,approved:=verified.trusted[c.approver]
	if !approved || approver.approval_seq>c.directory_version || !kind_policy(device_kind_from_id(approver.kind)).can_approve do return false
	epoch:u32
	for ep,proof in verified.epochs do if proof.start_seq<=c.directory_version && ep>epoch do epoch=ep
	if i64(epoch)!=c.epoch do return false
	message:=strings.concatenate({control_consent_domain(c.v),job.consent},context.temp_allocator)
	return verify(approver.sign_alg,approver.sign_public_key,transmute([]byte)message,job.signature)
}
// Wipe decoded plaintext copies as well as serialized results.
control_wipe_value :: proc(value:json.Value) {
	#partial switch v in value {
	case json.String:if len(v)>0 do crypto.zero_explicit(raw_data(v),len(v))
	case json.Object:for _,child in v do control_wipe_value(child)
	case json.Array:for child in v do control_wipe_value(child)
	}
}
control_transform_data :: proc(data:Control_Data,kr:^Vault_Keyring,details:=false)->(string,bool) {
	out:=data
	opened:=make([dynamic]json.Value,context.temp_allocator)
	defer for value in opened do control_wipe_value(value)
	transform :: proc(record:json.Object,kind:Control_Record_Kind,kr:^Vault_Keyring,opened:^[dynamic]json.Value)->(json.Object,bool) {
		text,ok:=control_record_json(kr,kind,record)
		if !ok do return nil,false
		defer if text!="" do crypto.zero_explicit(raw_data(text),len(text))
		value,err:=json.parse_string(text,parse_integers=true,allocator=context.temp_allocator)
		append(opened,value)
		obj,valid:=value.(json.Object)
		return obj,err==nil && valid
	}
	ok:=true
	if len(data.records)>0 {
		kind,known:=control_catalog_kind(data.records_kind);if !known do return "",false
		out.records=make([]json.Object,len(data.records),context.temp_allocator)
		for row,i in data.records {out.records[i],ok=transform(row,kind,kr,&opened);if !ok do return "",false}
	}
	if data.chain!=nil {out.chain,ok=transform(data.chain,.Chain,kr,&opened);if !ok do return "",false}
	out.chains=make([]json.Object,len(data.chains),context.temp_allocator)
	for c,i in data.chains {out.chains[i],ok=transform(c,.Chain,kr,&opened);if !ok do return "",false}
	out.tasks=make([]json.Object,len(data.tasks),context.temp_allocator)
	for t,i in data.tasks {out.tasks[i],ok=transform(t,.Task_Detail if details else .Task,kr,&opened);if !ok do return "",false}
	out.comments=make([]json.Object,len(data.comments),context.temp_allocator)
	for c,i in data.comments {out.comments[i],ok=transform(c,.Comment,kr,&opened);if !ok do return "",false}
	encoded,err:=json.marshal(out,allocator=context.temp_allocator)
	if err!=nil || len(encoded)>4*1024*1024 {
		if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
		return "",false
	}
	return string(encoded),true
}
control_job_transform :: proc(job:Control_Job,kr:^Vault_Keyring)->(string,bool) {
	if job.operation=="seal_resource" {
		value,err:=json.parse_string(job.payload,parse_integers=true,allocator=context.temp_allocator);defer control_wipe_value(value)
		fields,typed:=value.(json.Object);if err!=nil || !typed do return "",false
		return control_seal_resource_fields(kr,job.tool,fields)
	}
	if job.operation=="seal_agent" {
		value,err:=json.parse_string(job.payload,parse_integers=true,allocator=context.temp_allocator)
		defer control_wipe_value(value)
		fields,typed:=value.(json.Object);if err!=nil || !typed do return "",false
		return control_seal_agent_fields(kr,fields)
	}
	if job.operation=="seal_task" {
		value,err:=json.parse_string(job.payload,parse_integers=true,allocator=context.temp_allocator)
		defer control_wipe_value(value)
		fields,typed:=value.(json.Object)
		if err!=nil || !typed do return "",false
		return control_seal_task_fields(kr,fields)
	}
	if job.operation=="seal_comment" {
		input:struct {body:string}
		if json.unmarshal_string(job.payload,&input,.JSON,context.temp_allocator)!=nil do return "",false
		defer if input.body!="" do crypto.zero_explicit(raw_data(input.body),len(input.body))
		if kr==nil || !keyring_validate(kr) || len(input.body)<1 || len(input.body)>20000 do return "",false
		body,ok:=seal_string(input.body,kr,context.temp_allocator)
		if !ok do return "",false
		encoded,err:=json.marshal(struct {body:string}{body},allocator=context.temp_allocator)
		return string(encoded),err==nil
	}
	if job.operation=="read" {
		data:Control_Data
		if json.unmarshal_string(job.payload,&data,.JSON,context.temp_allocator)!=nil do return "",false
		if !control_catalog_data_ok(job.tool,data) do return "",false
		defer control_catalog_wipe(data)
		defer {
			control_wipe_value(data.chain)
			for row in data.chains do control_wipe_value(row)
			for row in data.tasks do control_wipe_value(row)
			for row in data.comments do control_wipe_value(row)
		}
		return control_transform_data(data,kr,job.tool=="tasks.get" || job.tool=="tasks.list")
	}
	input:struct {title,description:string}
	defer {if input.title!="" do crypto.zero_explicit(raw_data(input.title),len(input.title));if input.description!="" do crypto.zero_explicit(raw_data(input.description),len(input.description))}
	if job.operation!="seal" || json.unmarshal_string(job.payload,&input,.JSON,context.temp_allocator)!=nil do return "",false
	t,d,ok:=control_seal_chain(kr,input.title,input.description)
	if !ok do return "",false
	encoded,err:=json.marshal(struct {title,description:string}{t,d},allocator=context.temp_allocator)
	return string(encoded),err==nil
}
