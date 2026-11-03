#+feature dynamic-literals
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

Control_Record_Kind :: enum {Chain,Task,Comment,Task_Detail,Agent,Instance,Bridge,Provider,Memory,Project,Issue,Issue_Comment,Artifact}
// Return a request-owned JSON encoding. Callers must wipe it after forwarding or
// on any discarded-result path; never cache it. Input metadata is not mutated.
control_record_json :: proc(kr:^Vault_Keyring,kind:Control_Record_Kind,record:json.Object)->(string,bool) {
	if kr==nil || !keyring_validate(kr) do return "",false
	for key in ([]string{"owner_user_id","ownerUserId"}) {
		value,present:=record[key]
		if !present do continue
		owner,valid:=value.(json.String)
		read_only,_:=record["read_only"].(json.Boolean)
		if !valid || string(owner)!=keyring_user_id(kr) && !(kind==.Memory && string(owner)=="system" && bool(read_only)) do return "",false
	}
	out:=make(json.Object,context.temp_allocator)
	// Match the local four-tool POC's projection; never return full task briefs,
	// handoff/facet blobs or other nested encrypted business records by accident.
	allowed,fields:=control_record_fields(kind)
	for key in allowed do if value,present:=record[key];present do out[key]=value
	opened:=make([dynamic]string,context.temp_allocator)
	defer for plain in opened do if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain))
	nested:=make([dynamic]json.Value,context.temp_allocator)
	defer for value in nested do control_wipe_value(value)
	for key in fields {
		value,exists:=out[key]
		if !exists || value==nil do continue
		text,is_text:=value.(json.String)
		if !is_text do return "",false
		plain,ok:=control_text(kr,string(text))
		if !ok do return "",false
		append(&opened,plain);out[key]=json.String(plain)
	}
	if kind==.Artifact {
		if value,present:=out["content_base64"];present {
			token,typed:=value.(json.String)
			if _,text:=out["content"];text || !typed do return "",false
			encoded,ok:=control_artifact_bundle_open(kr,record,string(token));if !ok do return "",false
			append(&opened,encoded);out["content_base64"]=json.String(encoded)
		}
		if value,present:=out["content"];present {
			text,typed:=value.(json.String)
			if !typed || !control_artifact_type_ok(out) || !utf8.valid_string(string(text)) || len(text)>65536 || strings.contains(string(text),"\x00") do return "",false
		}
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
	if kind==.Provider {
		if value,present:=out["models"];present {
			models,typed:=value.(json.Array);if !typed || len(models)>100 do return "",false
			readable:=make(json.Array,0,len(models),context.temp_allocator)
			for item in models {
				model,object:=item.(json.Object);if !object || len(model)!=5 do return "",false
				id,id_ok:=model["model_id"].(json.String);label,label_ok:=model["label"].(json.String);state,state_ok:=model["state"].(json.String);rank,rank_ok:=model["rank"].(json.Integer);eligible,eligible_ok:=model["eligible"].(json.Boolean)
				if !id_ok || !label_ok || !state_ok || !rank_ok || !eligible_ok do return "",false
				plain,ok:=control_text(kr,string(label));if !ok do return "",false
				append(&opened,plain)
				entry:=make(json.Object,context.temp_allocator)
				entry["model_id"]=id;entry["label"]=json.String(plain);entry["state"]=state;entry["rank"]=rank;entry["eligible"]=eligible
				append(&readable,entry)
			}
			out["models"]=readable
		}
	}
	if kind==.Issue {
		if value,present:=out["description_limit"];present {
			limit,typed:=value.(json.Integer);if !typed || limit!=512 do return "",false
			if text,typed:=out["description"].(json.String);typed && len(text)>512 {
				end:=512;for end>0 && u8(text[end]) & 0xc0==0x80 do end-=1
				out["description"]=json.String(text[:end])
			}
		}
		if value,present:=out["comments"];present {
			items,typed:=value.(json.Array);if !typed || len(items)>100 do return "",false
			readable:=make(json.Array,0,len(items),context.temp_allocator)
			for item in items {
				row,object:=item.(json.Object);if !object do return "",false
				text,ok:=control_record_json(kr,.Issue_Comment,row);if !ok do return "",false
				plain,err:=json.parse_string(text,parse_integers=true,allocator=context.temp_allocator)
				append(&nested,plain)
				append(&opened,text);if err!=nil do return "",false
				append(&readable,plain)
			}
			out["comments"]=readable
		}
	}
	if kind==.Project {
		if value,present:=out["bridge_paths"];present {
			items,typed:=value.(json.Array);if !typed || len(items)>100 do return "",false
			for item in items {row,ok:=item.(json.Object);if !ok || len(row)!=5 do return "",false;for key in ([]string{"bridge_id","path","last_validated_at","updated_at"}) do if text,typed:=row[key].(json.String);!typed || len(text)>4096 do return "",false;if _,typed:=row["is_validated"].(json.Boolean);!typed do return "",false}
		}
	}
	if kind==.Memory {
		for key in ([]string{"agent_ids","project_ids","bridge_ids","template_ids"}) do if value,present:=out[key];present {
			items,typed:=value.(json.Array);if !typed || len(items)>100 do return "",false
			for item in items do if text,typed:=item.(json.String);!typed || len(text)>256 do return "",false
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
