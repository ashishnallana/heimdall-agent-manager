package main

// DEBUG (remove before merge): opt-in bridge log lines for the extension usage /
// rollover pipeline. Enabled by bridge env HEIMDALL_EXTENSION_DEBUG=1.

import "core:fmt"
import "core:os"

bridge_ext_debug_on :: proc() -> bool {
	return os.get_env("HEIMDALL_EXTENSION_DEBUG", context.temp_allocator) == "1"
}

bridge_ext_debugf :: proc(format: string, args: ..any) {
	if !bridge_ext_debug_on() do return
	fmt.eprintfln("ext-debug: %s", fmt.tprintf(format, ..args))
}

bridge_ext_debug_usage :: proc(instance_id, event: string, u: Bridge_Ext_Token_Usage) {
	if !bridge_ext_debug_on() do return
	pct: i64
	if u.context_window > 0 do pct = u.context_tokens * 100 / u.context_window
	bridge_ext_debugf("%s instance=%s context_tokens=%d context_pct=%d window=%d source=%s window_source=%v usage_supported=%v has_context=%v", event, instance_id, u.context_tokens, pct, u.context_window, u.context_source, u.window_source, u.usage_supported, u.has_context)
}
