package vault

import "core:encoding/json"
import "core:crypto"

// Only human prose is encrypted here. Assignment, dependency and approval
// metadata is separately parsed and authorized by the native task service.
control_seal_task_fields :: proc(kr:^Vault_Keyring,fields:json.Object)->(string,bool) {
	if kr==nil || !keyring_validate(kr) || len(fields)<1 || len(fields)>5 do return "",false
	out:=make(json.Object,context.temp_allocator)
	for key,value in fields {
		if key=="acceptance" {
			items,typed:=value.(json.Array)
			if !typed || len(items)<1 || len(items)>20 do return "",false
			sealed:=make(json.Array,0,len(items),context.temp_allocator)
			for item in items {
				text,valid:=item.(json.String);if !valid || len(text)<1 || len(text)>200 do return "",false
				token,ok:=seal_string(string(text),kr,context.temp_allocator);if !ok do return "",false
				append(&sealed,json.String(token))
			}
			out[key]=sealed
		} else {
			limit:=0
			switch key {case "title":limit=500;case "description","reason":limit=20000;case "goal":limit=2000;case:return "",false}
			text,typed:=value.(json.String);if !typed || len(text)>limit do return "",false
			token,ok:=seal_string(string(text),kr,context.temp_allocator);if !ok do return "",false
			out[key]=json.String(token)
		}
	}
	encoded,err:=json.marshal(out,allocator=context.temp_allocator)
	if err!=nil {if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded));return "",false}
	return string(encoded),true
}
