package main

import "core:os"
import "core:strings"

// bridge_make_directory_all creates path and only the MISSING tail components.
// core:os make_directory_all walks the whole path from the root, and on
// Android that means mkdir() on /data and /data/data, which the app sandbox
// answers with EACCES before it ever reports EEXIST — so creating
// ~/.config/heimdall/bridges/<id> failed with Permission_Denied on a phone even
// though every directory the bridge actually needed to create was its own.
// Here we walk UP to the deepest existing ancestor and mkdir DOWN from there,
// touching nothing that already exists. Same contract as the core proc:
// nil when the directory exists afterwards.
bridge_make_directory_all :: proc(path: string, perm: os.Permissions = {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) -> os.Error {
	clean := strings.trim_right(path, "/")
	if clean == "" || os.exists(clean) do return nil
	missing := make([dynamic]string, context.temp_allocator)
	cur := clean
	for {
		if os.exists(cur) do break
		append(&missing, cur)
		slash := strings.last_index_byte(cur, '/')
		if slash <= 0 do break
		cur = cur[:slash]
	}
	#reverse for dir in missing {
		if err := os.make_directory(dir, perm); err != nil && !os.exists(dir) do return err
	}
	return nil
}
