package vault

// Full read-time directory verification, mirroring vaultDirectoryVerify.ts.
// Device rows are cross-checks, never roots of trust. This module owns no keys.
import "core:encoding/json"

Directory_Log_Item :: struct {seq: i64, statement, signature: string}
Directory_Device_Item :: struct {
	id, kind, sign_alg, wrap_alg, sign_public_key, ecdh_public_key: string,
	approved, pending: bool,
}
Directory_Verification_Input :: struct {
	owner, root_device_id, head_hash: string,
	version, current_epoch: i64,
	log: []Directory_Log_Item,
	devices: []Directory_Device_Item,
	// A signed grant pins a full SHA256 log head, not just the short vault id.
	pin_seq: i64,
	pin_hash, vault_id: string,
}
Verified_Directory_Device :: struct {
	id, kind, sign_alg, wrap_alg, sign_public_key, ecdh_public_key: string,
	approval_seq: i64,
}
Verified_Directory_Epoch :: struct {commit: string, start_seq: i64}
Verified_Directory :: struct {
	owner, root_device_id, root_public_key, head_hash: string,
	vault_id: Vault_Id,
	version: i64,
	current_epoch: u32,
	trusted, ever_approved: map[string]Verified_Directory_Device,
	epochs: map[u32]Verified_Directory_Epoch,
	log_hashes: []string,
}

directory_decimal :: proc(text: string) -> (u64, bool) {
	if len(text)<1 || len(text)>16 || text[0]<'1' || text[0]>'9' do return 0,false
	return decimal_u64(text)
}
directory_subject :: proc(st: ^Statement, seq:i64) -> (Verified_Directory_Device,bool) {
	kind:=device_kind_from_id(st.subject_kind)
	if kind==.Unknown || sign_alg_from_id(st.subject_sign_alg)==.Unknown || !valid_p256_public_key(st.subject_sign_pub) do return {},false
	id,ok:=device_id_from_sign_pub(st.subject_sign_pub,context.temp_allocator)
	if !ok || id!=st.subject_device_id do return {},false
	policy:=kind_policy(kind)
	if policy.receives_wrap {
		if wrap_alg_from_id(st.subject_wrap_alg)==.Unknown || !valid_p256_public_key(st.subject_ecdh_pub) do return {},false
	} else if st.subject_wrap_alg!="" || st.subject_ecdh_pub!="" do return {},false
	if _,label_ok:=label_from_b64(st.subject_label_b64,context.temp_allocator);!label_ok do return {},false
	return {id,st.subject_kind,st.subject_sign_alg,st.subject_wrap_alg,st.subject_sign_pub,st.subject_ecdh_pub,seq},true
}
directory_same_subject :: proc(st:^Statement,d:Verified_Directory_Device)->bool {
	return st.subject_device_id==d.id && st.subject_kind==d.kind && st.subject_sign_alg==d.sign_alg && st.subject_wrap_alg==d.wrap_alg && st.subject_sign_pub==d.sign_public_key && st.subject_ecdh_pub==d.ecdh_public_key
}
directory_empty_subject :: proc(st:^Statement)->bool {
	return st.subject_device_id=="" && st.subject_kind=="" && st.subject_sign_pub=="" && st.subject_ecdh_pub=="" && st.subject_sign_alg=="" && st.subject_wrap_alg=="" && st.subject_label_b64==""
}
directory_commit_ok :: proc(text:string)->bool {return len(text)==64 && is_lower_hex(text)}

// All result allocations are public metadata in the caller's request arena.
// Callers must not retain this view beyond that arena's lifetime.
directory_verify :: proc(input:Directory_Verification_Input)->(Verified_Directory,bool) {
	if input.owner=="" || input.version<1 || input.version>65536 || i64(len(input.log))!=input.version || input.current_epoch<1 || input.current_epoch>i64(MAX_EPOCH) do return {},false
	out:=Verified_Directory{owner=input.owner,version=input.version,head_hash=input.head_hash,root_device_id=input.root_device_id,
		trusted=make(map[string]Verified_Directory_Device,context.temp_allocator),ever_approved=make(map[string]Verified_Directory_Device,context.temp_allocator),epochs=make(map[u32]Verified_Directory_Epoch,context.temp_allocator),log_hashes=make([]string,len(input.log),context.temp_allocator)}
	previous:=""
	epoch:u32
	for entry,i in input.log {
		seq:=i64(i+1)
		st,parsed:=statement_parse(entry.statement)
		if !parsed || entry.seq!=seq || st.user_id!=input.owner || st.prev_hash!=previous do return {},false
		n,seq_ok:=directory_decimal(st.seq)
		if !seq_ok || n!=u64(seq) do return {},false
		if _,time_ok:=directory_decimal(st.issued_at_ms);!time_ok do return {},false
		ep,ep_ok:=parse_epoch(st.epoch)
		if !ep_ok do return {},false
		if seq==1 {
			root,root_ok:=directory_subject(&st,seq)
			if !root_ok || !kind_policy(device_kind_from_id(root.kind)).can_approve || st.type!="genesis" || ep!=1 || !directory_commit_ok(st.epoch_commit) || st.issuer_device_id!=root.id || root.id!=input.root_device_id do return {},false
			if !verify(root.sign_alg,root.sign_public_key,transmute([]byte)entry.statement,entry.signature) do return {},false
			out.root_public_key=root.sign_public_key
			vid,vid_ok:=vault_id_from_root_sign_pub(root.sign_public_key)
			if !vid_ok do return {},false
			out.vault_id=vid
			out.trusted[root.id]=root;out.ever_approved[root.id]=root
			epoch=1;out.epochs[epoch]={st.epoch_commit,seq}
		} else {
			issuer,known:=out.trusted[st.issuer_device_id]
			if !known || !kind_policy(device_kind_from_id(issuer.kind)).can_approve || !verify(issuer.sign_alg,issuer.sign_public_key,transmute([]byte)entry.statement,entry.signature) do return {},false
			switch st.type {
			case "approve":
				d,subject_ok:=directory_subject(&st,seq)
				_,ever:=out.ever_approved[d.id]
				if !subject_ok || ever || ep!=epoch || st.epoch_commit!=out.epochs[epoch].commit do return {},false
				out.trusted[d.id]=d;out.ever_approved[d.id]=d
			case "revoke","rotate":
				if st.type=="revoke" {
					target,exists:=out.trusted[st.subject_device_id]
					if !exists || target.id==issuer.id || !directory_same_subject(&st,target) do return {},false
					delete_key(&out.trusted,target.id)
				} else if !directory_empty_subject(&st) do return {},false
				if epoch==MAX_EPOCH || ep!=epoch+1 || !directory_commit_ok(st.epoch_commit) || st.wrap_sha256!="" do return {},false
				epoch=ep;out.epochs[epoch]={st.epoch_commit,seq}
			case: return {},false
			}
		}
		previous=log_entry_hash(entry.statement,context.temp_allocator)
		out.log_hashes[i]=previous
	}
	if previous!=input.head_hash || epoch!=u32(input.current_epoch) do return {},false
	out.current_epoch=epoch
	if input.pin_seq<0 || input.pin_seq>input.version do return {},false
	if input.pin_seq>0 && out.log_hashes[input.pin_seq-1]!=input.pin_hash do return {},false
	if input.pin_seq==0 && input.pin_hash!="" do return {},false
	buf:[16]byte
	if input.vault_id!="" && vault_id_hex(out.vault_id,buf[:])!=input.vault_id do return {},false
	seen:=make(map[string]bool,context.temp_allocator)
	for row in input.devices {
		if seen[row.id] do return {},false
		seen[row.id]=true
		d,trusted:=out.trusted[row.id]
		if trusted && (!row.approved || row.kind!=d.kind || row.sign_alg!=d.sign_alg || row.wrap_alg!=d.wrap_alg || row.sign_public_key!=d.sign_public_key || row.ecdh_public_key!=d.ecdh_public_key) do return {},false
		_,ever:=out.ever_approved[row.id]
		if row.pending && ever do return {},false
	}
	for id in out.trusted do if !seen[id] do return {},false
	return out,true
}

// A wrap is signed by a currently trusted approver in the current epoch's log
// segment. Its recipient is supplied only after independent grant validation.
directory_verify_wrap :: proc(dir:^Verified_Directory,recipient:string,value:json.Value)->(Keyring_Wrap,bool) {
	if dir==nil do return {},false
	w,sig,parsed:=wrap_from_value_for_recipient(value,recipient,context.temp_allocator)
	if !parsed || w.current_epoch!=dir.current_epoch do return {},false
	start:=dir.epochs[dir.current_epoch].start_seq
	if w.directory_version<u64(start) || w.directory_version>u64(dir.version) do return {},false
	maker,trusted:=dir.trusted[w.wrapped_by_device_id]
	if !trusted || !kind_policy(device_kind_from_id(maker.kind)).can_approve do return {},false
	statement,ok:=wrap_statement(&w,dir.owner,context.temp_allocator)
	if !ok || !verify(maker.sign_alg,maker.sign_public_key,transmute([]byte)statement,sig) do return {},false
	return w,true
}

directory_verify_keyring :: proc(dir:^Verified_Directory,kr:^Vault_Keyring)->bool {
	if dir==nil || kr==nil || !keyring_validate(kr) || kr.vault_id!=dir.vault_id || kr.current_epoch!=dir.current_epoch || keyring_user_id(kr)!=dir.owner do return false
	for i in 0..<kr.count {
		entry:=&kr.entries[i]
		proof,known:=dir.epochs[entry.epoch]
		commit:[32]byte
		if !known || !hex_decode_into(commit[:],proof.commit) || !epoch_commit_verify(entry.key[:],dir.owner,entry.epoch,commit[:]) do return false
	}
	return true
}
