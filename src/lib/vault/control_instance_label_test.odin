#+feature dynamic-literals
package vault

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Native coordinator naming appends the per-agent run counter to the agent name,
// so an MCP-created (sealed) agent yields "<token> #n". The read transform must
// open such embedded labels and still fail closed on malformed armor.
@(test)
test_control_instance_label_opens_sealed_name_with_counter :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	v:struct {keyring_hex:string,entries:[]struct {job:Control_Job}}
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_artifacts_worker_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	bytes:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator);if !testing.expect(t,hex_decode_into(bytes,v.keyring_hex)) do return
	kr,parsed:=keyring_parse(bytes,v.entries[0].job.owner);if !testing.expect(t,parsed) do return
	defer keyring_wipe(&kr)
	owner:=json.String(keyring_user_id(&kr))
	token,sealed:=seal_string("Sealed coordinator",&kr);if !testing.expect(t,sealed) do return
	label:=proc(kr:^Vault_Keyring,owner:json.String,name:string)->(string,bool) {
		out,ok:=control_record_json(kr,.Instance,json.Object{"owner_user_id"=owner,"agent_instance_id"=json.String("inst_label"),"display_name"=json.String(name)})
		if !ok do return "",false
		value,_:=json.parse_string(out,allocator=context.temp_allocator)
		name,_:=value.(json.Object)["display_name"].(json.String)
		return string(name),true
	}
	for c in ([]struct {input,want:string}{
		{token,"Sealed coordinator"},
		{strings.concatenate({token," #3"}),"Sealed coordinator #3"},
		{"coordinator #7","coordinator #7"},
	}) {
		got,ok:=label(&kr,owner,c.input)
		testing.expectf(t,ok && got==c.want,"label %q: ok=%v got %q",c.want,ok,got)
	}
	// Truncated, tampered, or stray armor never yields plaintext or ciphertext.
	for bad in ([]string{
		strings.concatenate({token[:len(token)-8]," #3"}),
		strings.concatenate({token[:len(token)-4],"AAAA #3"}),
		strings.concatenate({token," #3 vault:v2:zz"}),
		"vault:v2:not-a-token #3",
	}) {
		_,ok:=label(&kr,owner,bad)
		testing.expectf(t,!ok,"malformed label must fail closed: %q",bad)
	}
}
