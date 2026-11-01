package main

import "core:testing"
import bridgesvc "odin_test:lib/bridgesvc"

@(test)
test_service_runtime_requires_exact_profile_and_current_pid :: proc(t: ^testing.T) {
	rt := bridgesvc.Runtime_Status{pid = 42, updated_at = 200}
	expected := "/profiles/p1/bin/ham-bridge.exe"
	testing.expect(t, bridge_service_runtime_matches(rt, 7, 100, expected, expected, true), "live process belongs to this profile even when its launcher exited")
	testing.expect(t, !bridge_service_runtime_matches(rt, 42, 100, expected, expected, true), "never target the CLI itself")
	testing.expect(t, !bridge_service_runtime_matches(rt, 7, 201, expected, expected, true), "PID reused after runtime record")
	testing.expect(t, !bridge_service_runtime_matches(rt, 7, 0, expected, expected, true), "unknown process start time")
	testing.expect(t, !bridge_service_runtime_matches(rt, 7, 100, "/profiles/p2/bin/ham-bridge.exe", expected, true), "another profile has the same executable name")
	testing.expect(t, !bridge_service_runtime_matches(rt, 7, 100, "/profiles/p1/bin/other.exe", expected, true), "unrelated executable")
	testing.expect(t, !bridge_service_runtime_matches(rt, 7, 100, expected, expected, false), "unknown image fails closed")
	when ODIN_OS == .Windows {
		testing.expect(t, bridge_service_runtime_matches(rt, 7, 100, "C:\\Profiles\\P1\\bin\\ham-bridge.exe", "c:/profiles/p1/bin/ham-bridge.exe", true), "Windows separators and case are equivalent")
	}
}
