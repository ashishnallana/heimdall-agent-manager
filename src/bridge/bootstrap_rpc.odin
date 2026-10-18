package main

// BRG-3 wrapper-facing bootstrap RPCs.
//
// The bridge does the hub-facing conditional fetch + assembly, then PUBLISHES the
// finished file set for an instance into an in-memory store. The wrapper (which
// only talks to the local socket) drives materialization with two small,
// list-driven RPCs so there is never a large bundled payload:
//
//   wrapper.bootstrap.list(instance_id) -> {files:[{file_id, kind, relative_path, mode}]}
//   wrapper.bootstrap.file(instance_id, file_id) -> {file_id, kind, relative_path, mode, content}
//
// The wrapper writes each returned file to relative_path (chmod +x when mode is
// 0755). Placement paths are resolved BY THE BRIDGE (provider layout) and
// delivered as data, so the wrapper needs no provider knowledge.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

Bridge_Bootstrap_Fileset_Entry :: struct {
	instance_id: string,
	provider:    string,
	files:       [dynamic]Bridge_Bootstrap_File,
}

bridge_bootstrap_fileset_mutex: sync.Mutex
bridge_bootstrap_filesets: map[string]Bridge_Bootstrap_Fileset_Entry

// bridge_bootstrap_fileset_store_put publishes (a clone of) the finished file set
// for an instance, replacing any previous set. Safe to call on every (re)launch.
// `provider` lets the list RPC surface the provider layout override values
// (bootstrap_file_name, skill_dir) as data so the wrapper owns kind->path
// placement (PROV-1) without provider knowledge baked into the wrapper binary.
bridge_bootstrap_fileset_store_put :: proc(instance_id, provider: string, files: []Bridge_Bootstrap_File) {
	if strings.trim_space(instance_id) == "" do return
	sync.mutex_lock(&bridge_bootstrap_fileset_mutex)
	defer sync.mutex_unlock(&bridge_bootstrap_fileset_mutex)
	if bridge_bootstrap_filesets == nil do bridge_bootstrap_filesets = make(map[string]Bridge_Bootstrap_Fileset_Entry)
	// Free any prior set for this instance.
	if existing, ok := bridge_bootstrap_filesets[instance_id]; ok {
		for f in existing.files { delete(f.file_id); delete(f.relative_path); delete(f.content) }
		delete(existing.files)
		delete(existing.instance_id)
		delete(existing.provider)
		delete_key(&bridge_bootstrap_filesets, instance_id)
	}
	cloned := make([dynamic]Bridge_Bootstrap_File)
	for f in files {
		append(&cloned, Bridge_Bootstrap_File{
			file_id       = strings.clone(f.file_id),
			relative_path = strings.clone(f.relative_path),
			kind          = f.kind, // string literal, not owned
			content       = strings.clone(f.content),
			mode          = f.mode,
		})
	}
	bridge_bootstrap_filesets[strings.clone(instance_id)] = Bridge_Bootstrap_Fileset_Entry{instance_id = strings.clone(instance_id), provider = strings.clone(provider), files = cloned}
}

// bridge_bootstrap_fileset_list returns the file metadata (no content) for an
// instance as a JSON array string, and whether the instance is known.
bridge_bootstrap_fileset_list_json :: proc(instance_id: string) -> (string, bool) {
	sync.mutex_lock(&bridge_bootstrap_fileset_mutex)
	defer sync.mutex_unlock(&bridge_bootstrap_fileset_mutex)
	entry, ok := bridge_bootstrap_filesets[instance_id]
	if !ok do return "", false
	b := strings.builder_make()
	strings.write_string(&b, "{\"files\":[")
	for f, i in entry.files {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"file_id\":\""); bridge_local_write_json_string(&b, f.file_id)
		strings.write_string(&b, "\",\"kind\":\""); bridge_local_write_json_string(&b, f.kind)
		strings.write_string(&b, "\",\"relative_path\":\""); bridge_local_write_json_string(&b, f.relative_path)
		strings.write_string(&b, "\",\"mode\":"); fmt.sbprintf(&b, "%d", f.mode)
		strings.write_byte(&b, '}')
	}
	// layout: provider placement override values (PROV-1) so the wrapper can resolve
	// kind->path itself. relative_path above is the bridge-resolved convenience;
	// these are the raw override inputs the wrapper may prefer to place with.
	bootstrap_file_name := ""
	skill_dir := ""
	if profile, prof_ok := bridge_provider_by_name_or_default(entry.provider); prof_ok {
		bootstrap_file_name = strings.trim_space(profile.bootstrap_file_name)
		skill_dir = strings.trim_space(profile.skill_dir)
	}
	strings.write_string(&b, "],\"layout\":{\"provider\":\""); bridge_local_write_json_string(&b, entry.provider)
	strings.write_string(&b, "\",\"bootstrap_file_name\":\""); bridge_local_write_json_string(&b, bootstrap_file_name)
	strings.write_string(&b, "\",\"skill_dir\":\""); bridge_local_write_json_string(&b, skill_dir)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b), true
}

// bridge_bootstrap_fileset_store_write_run_dir writes the stored fileset for an
// instance directly to run_dir. Used by the pty-host fallback path after
// bridge_bootstrap_fetch_manifest_and_materialize publishes to the store without
// writing to disk (the function was built for the wrapper path where the wrapper
// is the disk writer). Returns false if the instance is unknown or any write fails.
bridge_bootstrap_fileset_store_write_run_dir :: proc(instance_id, run_dir: string) -> bool {
	clean := strings.trim_right(run_dir, "/")
	if strings.trim_space(clean) == "" || strings.trim_space(instance_id) == "" do return false
	sync.mutex_lock(&bridge_bootstrap_fileset_mutex)
	defer sync.mutex_unlock(&bridge_bootstrap_fileset_mutex)
	entry, ok := bridge_bootstrap_filesets[instance_id]
	if !ok do return false
	for f in entry.files {
		rel := strings.trim_left(f.relative_path, "/")
		if strings.trim_space(rel) == "" do continue
		full := strings.concatenate({clean, "/", rel})
		if slash := strings.last_index_byte(full, '/'); slash > 0 {
			parent := full[:slash]
			_ = bridge_make_directory_all(parent)
		}
		write_err := os.write_entire_file(full, transmute([]byte)f.content)
		if f.mode == 0o755 && write_err == nil {
			bridge_os_make_owner_executable(full)
		}
		delete(full)
		if write_err != nil do return false
	}
	return true
}

// bridge_bootstrap_fileset_file_json returns one file (with content) for an
// instance as a JSON object string. ok=false if the instance or file is unknown.
bridge_bootstrap_fileset_file_json :: proc(instance_id, file_id: string) -> (string, bool) {
	sync.mutex_lock(&bridge_bootstrap_fileset_mutex)
	defer sync.mutex_unlock(&bridge_bootstrap_fileset_mutex)
	entry, ok := bridge_bootstrap_filesets[instance_id]
	if !ok do return "", false
	for f in entry.files {
		if f.file_id != file_id do continue
		b := strings.builder_make()
		strings.write_string(&b, "{\"file_id\":\""); bridge_local_write_json_string(&b, f.file_id)
		strings.write_string(&b, "\",\"kind\":\""); bridge_local_write_json_string(&b, f.kind)
		strings.write_string(&b, "\",\"relative_path\":\""); bridge_local_write_json_string(&b, f.relative_path)
		strings.write_string(&b, "\",\"mode\":"); fmt.sbprintf(&b, "%d", f.mode)
		strings.write_string(&b, ",\"content\":\""); bridge_local_write_json_string(&b, f.content)
		strings.write_string(&b, "\"}")
		return strings.to_string(b), true
	}
	return "", false
}
