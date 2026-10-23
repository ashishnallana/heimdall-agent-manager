package content

import "core:crypto/sha2"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// The persisted message is the deduplication receipt, so an HTTP timeout or hub
// restart cannot duplicate the ready note. The launch epoch is authoritative;
// run_count/started_at distinguish legacy instances with no epoch.
startup_message_id :: proc(inst: domain.Agent_Instance) -> string {
	key := fmt.tprintf("%s\n%s\n%d\n%s", inst.agent_instance_id, inst.launch_epoch, inst.run_count, inst.started_at)
	digest: [32]byte
	hash: sha2.Context_256
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]byte)key)
	sha2.final(&hash, digest[:])
	b := strings.builder_make()
	strings.write_string(&b, "msg_start_")
	for c in digest do strings.write_string(&b, fmt.tprintf("%02x", c))
	return strings.to_string(b)
}

startup_message_mutex: sync.Mutex

get_agent_startup_message :: proc(s: ^Content_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id != inst.agent_instance_id || auth.user_id != string(inst.owner_user_id) do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	id := startup_message_id(inst)
	defer delete(id)
	return iface.content_get_message(s.content, id)
}

// created=false with no error is a duplicate. Keep the original note unchanged,
// including its read state and conversation unread count.
send_agent_startup_message :: proc(s: ^Content_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance) -> (message: domain.Chat_Message, created: bool, err: domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id != inst.agent_instance_id || auth.user_id != string(inst.owner_user_id) do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	id := startup_message_id(inst)
	sync.mutex_lock(&startup_message_mutex)
	defer sync.mutex_unlock(&startup_message_mutex)
	if saved, exists, read_err := iface.content_get_message(s.content, id); exists {
		delete(id)
		return saved, false, {}
	} else if read_err.code != .None && read_err.code != .Not_Found {
		delete(id)
		return {}, false, read_err
	}
	return send_agent_message_with_id(s, auth, inst.agent_instance_id, Message_Input{body = "Agent has started and is ready.", artifact_ids_json = "[]", message_type = "system"}, id)
}
