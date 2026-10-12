package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

Bootstrap_Cache_Item :: struct {
	hash: string,
	path: string,
	size_bytes: int,
	last_access_ns: i64,
}

Bootstrap_Cache :: struct {
	base_dir: string,
	blobs_dir: string,
	max_bytes: int,
	total_bytes: int,
	items: map[string]Bootstrap_Cache_Item,
	lock: sync.Mutex,
}

bootstrap_cache_hash_filename :: proc(hash_str: string) -> string {
	if strings.has_prefix(hash_str, "sha256:") {
		return hash_str[7:]
	}
	return hash_str
}

bootstrap_cache_verify_hash :: proc(body, expected_hash: string) -> bool {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, body, buf[:])
	hex_str := hex.encode(buf[:])
	defer delete(hex_str)
	actual := strings.concatenate({"sha256:", string(hex_str)})
	defer delete(actual)
	return strings.equal_fold(actual, expected_hash)
}

bootstrap_cache_init :: proc(cache: ^Bootstrap_Cache, base_dir: string, max_bytes: int) {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	cache.base_dir = strings.clone(base_dir)
	cache.blobs_dir = strings.concatenate({strings.trim_right(base_dir, "/"), "/bootstrap-cache/blobs"})
	cache.max_bytes = max_bytes if max_bytes > 0 else 256 * 1024 * 1024
	cache.items = make(map[string]Bootstrap_Cache_Item)
	cache.total_bytes = 0
	_ = bridge_make_directory_all(cache.blobs_dir)

	if handle, err := os.open(cache.blobs_dir); err == nil {
		defer os.close(handle)
		if fi_list, read_err := os.read_dir(handle, -1, context.allocator); read_err == nil {
			defer os.file_info_slice_delete(fi_list, context.allocator)
			for fi in fi_list {
				if fi.type == .Directory || strings.has_suffix(fi.name, ".tmp") do continue
				full_path := strings.concatenate({cache.blobs_dir, "/", fi.name})
				hash_key := strings.concatenate({"sha256:", fi.name})
				size := int(fi.size)
				access_time := time.to_unix_nanoseconds(time.now())
				cache.items[hash_key] = Bootstrap_Cache_Item{
					hash = hash_key,
					path = full_path,
					size_bytes = size,
					last_access_ns = access_time,
				}
				cache.total_bytes += size
			}
		}
	}
}

// -----------------------------------------------------------------------------
// Manifest + ETag store (BRG-1): persist the last conditional-manifest response
// per (agent_id, role, provider, project) next to the blob cache so a warm launch
// can send If-None-Match and, on a 304, reuse the cached manifest with zero blob
// fetches. The key is sanitized to a safe filename; the value is the raw manifest
// JSON with its ETag on the first line ("ETag: <etag>\n<manifest-json>").
// -----------------------------------------------------------------------------

bootstrap_manifest_store_dir :: proc(cache: ^Bootstrap_Cache) -> string {
	return strings.concatenate({strings.trim_right(cache.base_dir, "/"), "/bootstrap-cache/manifests"})
}

// bootstrap_manifest_key_filename maps a (agent,role,provider,project) key to a
// safe flat filename (non-alphanumerics collapsed to '_').
bootstrap_manifest_key_filename :: proc(agent_id, role, provider, project: string) -> string {
	raw := strings.concatenate({agent_id, "_", role, "_", provider, "_", project})
	defer delete(raw)
	b := strings.builder_make()
	for i in 0..<len(raw) {
		ch := raw[i]
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_': strings.write_byte(&b, ch)
		case: strings.write_byte(&b, '_')
		}
	}
	strings.write_string(&b, ".manifest")
	return strings.to_string(b)
}

bootstrap_manifest_store_path :: proc(cache: ^Bootstrap_Cache, agent_id, role, provider, project: string) -> string {
	dir := bootstrap_manifest_store_dir(cache)
	defer delete(dir)
	name := bootstrap_manifest_key_filename(agent_id, role, provider, project)
	defer delete(name)
	return strings.concatenate({dir, "/", name})
}

// bootstrap_manifest_store_save persists the ETag + manifest JSON for a key.
bootstrap_manifest_store_save :: proc(cache: ^Bootstrap_Cache, agent_id, role, provider, project, etag, manifest_json: string) -> bool {
	dir := bootstrap_manifest_store_dir(cache)
	defer delete(dir)
	_ = bridge_make_directory_all(dir)
	path := bootstrap_manifest_store_path(cache, agent_id, role, provider, project)
	defer delete(path)
	body := strings.concatenate({"ETag: ", etag, "\n", manifest_json})
	defer delete(body)
	return os.write_entire_file(path, body) == nil
}

// bootstrap_manifest_store_load returns (etag, manifest_json, ok) for a key.
bootstrap_manifest_store_load :: proc(cache: ^Bootstrap_Cache, agent_id, role, provider, project: string) -> (string, string, bool) {
	path := bootstrap_manifest_store_path(cache, agent_id, role, provider, project)
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", "", false
	text := string(data)
	nl := strings.index_byte(text, '\n')
	if nl < 0 do return "", "", false
	first := text[:nl]
	if !strings.has_prefix(first, "ETag: ") do return "", "", false
	etag := strings.clone(strings.trim_space(first[len("ETag: "):]))
	manifest_json := strings.clone(text[nl + 1:])
	delete(data)
	return etag, manifest_json, true
}

bootstrap_cache_has :: proc(cache: ^Bootstrap_Cache, hash_str: string) -> bool {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	item, ok := cache.items[hash_str]
	if !ok do return false
	if _, err := os.stat(item.path, context.allocator); err != nil {
		delete(item.hash)
		delete(item.path)
		delete_key(&cache.items, hash_str)
		cache.total_bytes -= item.size_bytes
		return false
	}
	return true
}

bootstrap_cache_get :: proc(cache: ^Bootstrap_Cache, hash_str: string) -> (string, bool) {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	item, ok := cache.items[hash_str]
	if !ok do return "", false
	data, err := os.read_entire_file(item.path, context.allocator)
	if err != nil {
		delete(item.hash)
		delete(item.path)
		delete_key(&cache.items, hash_str)
		cache.total_bytes -= item.size_bytes
		return "", false
	}
	item.last_access_ns = time.to_unix_nanoseconds(time.now())
	cache.items[hash_str] = item
	return string(data), true
}

bootstrap_cache_put :: proc(cache: ^Bootstrap_Cache, hash_str, body: string) -> bool {
	if !bootstrap_cache_verify_hash(body, hash_str) {
		fmt.eprintln("bootstrap cache hash verification failed for", hash_str)
		return false
	}
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)

	filename := bootstrap_cache_hash_filename(hash_str)
	blob_path := strings.concatenate({cache.blobs_dir, "/", filename})
	defer delete(blob_path)
	tmp_filename := fmt.tprintf("%s.%d.tmp", filename, time.now()._nsec)
	tmp_path := strings.concatenate({cache.blobs_dir, "/", tmp_filename})
	defer delete(tmp_path)

	_ = bridge_make_directory_all(cache.blobs_dir)
	if os.write_entire_file(tmp_path, body) != nil {
		_ = os.remove(tmp_path)
		return false
	}
	if os.rename(tmp_path, blob_path) != nil {
		_ = os.remove(tmp_path)
		return false
	}

	size := len(body)
	if existing, exists := cache.items[hash_str]; exists {
		cache.total_bytes -= existing.size_bytes
		delete(existing.hash)
		delete(existing.path)
		delete_key(&cache.items, hash_str)
	}
	// The map key MUST be an owned clone: Odin maps store the string header without
	// copying the bytes, so using the caller's transient `hash_str` as the key
	// leaves a dangling key once the caller frees it (crashes/misses on later
	// lookups). Key the map on a stable clone (same buffer as the item's hash).
	key_clone := strings.clone(hash_str)
	cache.items[key_clone] = Bootstrap_Cache_Item{
		hash = strings.clone(hash_str),
		path = strings.clone(blob_path),
		size_bytes = size,
		last_access_ns = time.to_unix_nanoseconds(time.now()),
	}
	cache.total_bytes += size

	bootstrap_cache_evict_lru_locked(cache)
	return true
}

bootstrap_cache_evict_lru_locked :: proc(cache: ^Bootstrap_Cache) {
	for cache.total_bytes > cache.max_bytes && len(cache.items) > 0 {
		oldest_hash := ""
		oldest_ns: i64 = 1<<62
		for k, v in cache.items {
			if v.last_access_ns < oldest_ns {
				oldest_ns = v.last_access_ns
				oldest_hash = k
			}
		}
		if oldest_hash == "" do break
		oldest_item := cache.items[oldest_hash]
		_ = os.remove(oldest_item.path)
		cache.total_bytes -= oldest_item.size_bytes
		delete(oldest_item.hash)
		delete(oldest_item.path)
		delete_key(&cache.items, oldest_hash)
	}
}
