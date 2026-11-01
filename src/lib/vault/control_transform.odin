package vault

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

// Hosted transforms fail closed. Unlike a locked interactive UI, they never
// forward a ciphertext placeholder as though it were a successfully read result.
control_text :: proc(kr:^Vault_Keyring,text:string)->(string,bool) {
	if kr==nil do return "",false
	if is_armored(text) {
		plain,result:=open(text,kr,context.temp_allocator)
		if result!=.Ok || !utf8.valid_string(plain) {if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain));return "",false}
		return plain,true
	}
	if !strings.contains(text,VAULT_V2_PREFIX) do return strings.clone(text,context.temp_allocator),true
	pos:=0
	b:strings.Builder
	strings.builder_init(&b,context.temp_allocator)
	completed:=false
	defer if !completed {
		partial:=strings.to_string(b)
		if partial!="" do crypto.zero_explicit(raw_data(partial),len(partial))
	}
	for pos<len(text) {
		start,end:=next_token(text,pos)
		if start<0 {
			if strings.contains(text[pos:],VAULT_V2_PREFIX) do return "",false
			strings.write_string(&b,text[pos:]);break
		}
		if strings.contains(text[pos:start],VAULT_V2_PREFIX) do return "",false
		strings.write_string(&b,text[pos:start])
		plain,result:=open(text[start:end],kr,context.temp_allocator)
		if result!=.Ok || !utf8.valid_string(plain) {if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain));return "",false}
		strings.write_string(&b,plain)
		if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain))
		pos=end
	}
	completed=true
	return strings.to_string(b),true
}

Control_Record_Kind :: enum {Chain,Task,Comment,Task_Detail}
// Return a request-owned JSON encoding. Callers must wipe it after forwarding or
// on any discarded-result path; never cache it. Input metadata is not mutated.
control_record_json :: proc(kr:^Vault_Keyring,kind:Control_Record_Kind,record:json.Object)->(string,bool) {
	if kr==nil || !keyring_validate(kr) do return "",false
	for key in ([]string{"owner_user_id","ownerUserId"}) {
		value,present:=record[key]
		if !present do continue
		owner,valid:=value.(json.String)
		if !valid || string(owner)!=keyring_user_id(kr) do return "",false
	}
	out:=make(json.Object,context.temp_allocator)
	// Match the local four-tool POC's projection; never return full task briefs,
	// handoff/facet blobs or other nested encrypted business records by accident.
	allowed,fields:=control_record_fields(kind)
	for key in allowed do if value,present:=record[key];present do out[key]=value
	opened:=make([dynamic]string,context.temp_allocator)
	defer for plain in opened do if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain))
	for key in fields {
		value,exists:=out[key]
		if !exists || value==nil do continue
		text,is_text:=value.(json.String)
		if !is_text do return "",false
		plain,ok:=control_text(kr,string(text))
		if !ok do return "",false
		append(&opened,plain);out[key]=json.String(plain)
	}
	if kind==.Task_Detail {
		for key in ([]string{"acceptance","inputs"}) do if value,present:=out[key];present {
			items,typed:=value.(json.Array)
			if !typed do return "",false
			readable:=make(json.Array,0,len(items),context.temp_allocator)
			for item in items {
				text,valid:=item.(json.String);if !valid do return "",false
				plain,ok:=control_text(kr,string(text));if !ok do return "",false
				append(&opened,plain);append(&readable,json.String(plain))
			}
			out[key]=readable
		}
	}
	data,err:=json.marshal(out,allocator=context.temp_allocator)
	if err==nil && strings.contains(string(data),VAULT_V2_PREFIX) {
		crypto.zero_explicit(raw_data(data),len(data))
		return "",false
	}
	return string(data),err==nil
}

// Creation always encrypts these fields under this request's VERIFIED current
// epoch. No global vault session and no plaintext fallback exist in the Hub.
control_seal_chain :: proc(kr:^Vault_Keyring,title,description:string)->(sealed_title,sealed_description:string,ok:bool) {
	if kr==nil || !keyring_validate(kr) do return "","",false
	t,tok:=seal_string(title,kr,context.temp_allocator)
	if !tok do return "","",false
	d,dok:=seal_string(description,kr,context.temp_allocator)
	if !dok do return "","",false
	return t,d,true
}
