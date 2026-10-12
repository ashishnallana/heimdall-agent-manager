package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:strings"
import "core:time"

// Creates only the missing tail; existing ancestors are never mkdir()ed.
@(test)
test_bridge_make_directory_all_creates_missing_tail_only :: proc(t: ^testing.T) {
	base := fmt.tprintf("%s/ham-mkdir-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	testing.expect_value(t, os.make_directory(base), nil)
	defer os.remove_all(base)
	deep := strings.concatenate({base, "/a/b/c/"}, context.temp_allocator)
	testing.expect_value(t, bridge_make_directory_all(deep), nil)
	testing.expect(t, os.exists(strings.concatenate({base, "/a/b/c"}, context.temp_allocator)), "created")
	testing.expect_value(t, bridge_make_directory_all(deep), nil) // idempotent
	testing.expect_value(t, bridge_make_directory_all(base), nil)  // exists already
	testing.expect_value(t, bridge_make_directory_all(strings.concatenate({base, "/x"}, context.temp_allocator)), nil)
	testing.expect(t, os.exists(strings.concatenate({base, "/x"}, context.temp_allocator)), "single missing component")
}
