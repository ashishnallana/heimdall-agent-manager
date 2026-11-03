package mcp

import "core:strings"
import vault "odin_test:lib/vault"

// The adapter owns a native UOW: recheck delegated authority, prepare the chain
// and coordinator atomically, commit, then dispatch the launch. A nonempty
// chain_id on error means creation committed; callers must not retry it.
Control_Create_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,args:Control_Arguments,title,description:string)->(chain_id,instance_id,error:string)

control_coordinator_arguments_ok :: proc(args:Control_Arguments)->bool {
	return strings.has_prefix(args.coordinator_agent_id,"agt_") && len(args.coordinator_agent_id)>4 && len(args.coordinator_agent_id)<=256 && vault.valid_id_value(args.coordinator_agent_id) &&
		strings.has_prefix(args.bridge_id,"brg_") && len(args.bridge_id)>4 && len(args.bridge_id)<=256 && vault.valid_id_value(args.bridge_id)
}
