package main

import "core:os"
import "core:strings"

// bridge_scratch_root is where the bridge keeps per-process scratch (fallback
// Unix socket directories, the default local run dir, telemetry config). It is
// $TMPDIR when that is an absolute path, else /tmp. Termux/Android has no
// writable /tmp at all (TMPDIR=$PREFIX/tmp), which is how the PTY host failed
// with "cannot prepare socket directory /tmp/heimdall-<uid>/..." on a phone.
bridge_scratch_root :: proc(allocator := context.allocator) -> string {
	if raw, found := os.lookup_env("TMPDIR", context.temp_allocator); found {
		t := strings.trim_right(strings.trim_space(raw), "/")
		if strings.has_prefix(t, "/") do return strings.clone(t, allocator)
	}
	return strings.clone("/tmp", allocator)
}

// bridge_scratch_local_default is the default --local-run-dir.
bridge_scratch_local_default :: proc(allocator := context.allocator) -> string {
	root := bridge_scratch_root(context.temp_allocator)
	return strings.concatenate({root, "/heimdall-bridge-local"}, allocator)
}
