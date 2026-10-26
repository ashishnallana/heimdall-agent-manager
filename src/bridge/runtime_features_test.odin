package main

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"

// Hello and the legacy heartbeat must advertise the same features: the hub replaces
// its stored feature list on every frame, so a feature missing from the heartbeat is
// withdrawn ~45s after connect (the lost tool_stream_demand_v2 regression).

@(private = "file")
runtime_features_member :: proc(frame: string) -> string {
	start := strings.index(frame, `"features":[`)
	if start < 0 do return ""
	start += len(`"features":`)
	end := strings.index_byte(frame[start:], ']')
	if end < 0 do return ""
	return frame[start:start + end + 1]
}

@(test)
test_bridge_hello_and_heartbeats_advertise_the_same_runtime_features :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	// Stats fork `ps` and ensure a real pty-host daemon; features do not need them.
	bridge_heartbeat_stats_set_enabled(false)
	defer bridge_heartbeat_stats_set_enabled(true)

	// The heartbeat serializer is exactly the shared source, element for element.
	shared := bridge_runtime_features_json()
	value, err := json.parse_string(shared, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	arr, is_arr := value.(json.Array)
	testing.expect(t, is_arr, "features serialize as a JSON array")
	testing.expect_value(t, len(arr), len(BRIDGE_RUNTIME_FEATURES))
	has_tool_stream := false
	for feature, i in BRIDGE_RUNTIME_FEATURES {
		if feature == "tool_stream_demand_v2" do has_tool_stream = true
		if i < len(arr) {
			s, is_str := arr[i].(json.String)
			testing.expect(t, is_str && string(s) == feature, "serialized feature matches the shared source")
		}
	}
	testing.expect(t, has_tool_stream, "the shared source advertises tool_stream_demand_v2")

	hello := bridge_hub_hello_json()
	defer delete(hello)
	testing.expect_value(t, runtime_features_member(hello), shared)

	testing.expect(t, strings.contains(shared, `"heartbeat_metadata_omission"`), "hello advertises heartbeat metadata omission support")

	// Repeated legacy heartbeats (what a hub without heartbeat_metadata_omission
	// receives): every one carries the complete list, never a stale subset.
	for _ in 0 ..< 3 {
		hb := bridge_hub_heartbeat_json_shaped({})
		defer delete(hb)
		testing.expect_value(t, runtime_features_member(hb), shared)
	}
}
