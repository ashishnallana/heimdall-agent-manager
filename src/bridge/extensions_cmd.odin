package main

// Provider extensions as a step of setup and update (F10).
//
// `ham-bridge setup` (step `extensions`) and `ham-bridge extensions sync`
// (run by ham-bridge update after the swap) both:
//   1. copy the release bundle's share/heimdall/extensions into
//      <data dir>/extensions, where the running bridge resolves it (F11);
//   2. publish it, once per release, to the profile-neutral shared root
//      <data root>/.shared-extensions/<version>/extensions that every bridge
//      profile (Ninjy account) of this OS user registers from;
//   3. bring every detected provider's Heimdall extension to the newest shared
//      release with bridge_extension_ensure, which self-heals foreign, outdated
//      and half-installed registrations (ENR-12).
// A provider that still fails after self-healing is reported, not fatal: the
// bridge itself is installed and can retry from the Hub.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"

BRIDGE_EXTENSION_PROVIDERS :: [?]string{"claude", "codex", "antigravity"}
// Per provider, matching the Hub-frame path; there is no shared cap, so a slow
// CLI cannot leave a later provider starting with its deadline already passed.
BRIDGE_EXTENSION_PROVIDER_TIMEOUT :: 55 * time.Second

// One provider's outcome; `line` is human-readable.
Bridge_Extension_Sync_Line :: struct {
	provider: string,
	ok:       bool,
	skipped:  bool, // provider CLI not detected
	line:     string,
}

bridge_extension_variant_dir :: proc(provider: string) -> string {
	return "claude-code" if bridge_extension_canonical_provider(provider) == "claude" else provider
}

// bridge_extensions_bundle_source finds the extensions a release bundle ships
// next to bin/ (share/heimdall/extensions), or "" when it carries none.
bridge_extensions_bundle_source :: proc(bundle_bin_dir: string) -> string {
	root := bridgesvc.pdir(strings.trim_right(bundle_bin_dir, "/\\"))
	for c in ([]string{
		bridgesvc.pjoin(root, "share", "heimdall", "extensions"),
		bridgesvc.pjoin(bundle_bin_dir, "share", "heimdall", "extensions"),
		bridgesvc.pjoin(root, "extensions"),
	}) {
		if os.is_dir(c) do return c
	}
	return ""
}

bridge_extensions_copy_tree :: proc(src, dst: string) -> (ok: bool, msg: string) {
	if err := os.make_directory_all(dst); err != nil && !os.is_dir(dst) do return false, fmt.tprintf("cannot create %s: %v", dst, err)
	infos, rerr := os.read_directory_by_path(src, -1, context.temp_allocator)
	if rerr != nil do return false, fmt.tprintf("cannot read %s: %v", src, rerr)
	for info in infos {
		from := bridgesvc.pjoin(src, info.name)
		to := bridgesvc.pjoin(dst, info.name)
		if os.is_dir(from) {
			if sub_ok, sub_msg := bridge_extensions_copy_tree(from, to); !sub_ok do return false, sub_msg
		} else if err := os.copy_file(to, from); err != nil {
			return false, fmt.tprintf("copy %s: %v", from, err)
		}
	}
	return true, ""
}

// bridge_extensions_install_bundle replaces <data_dir>/extensions with src,
// keeping the previous copy at extensions.bak until bridge_extensions_restore
// or the next install. Copying onto itself is a no-op.
bridge_extensions_install_bundle :: proc(src, data_dir: string) -> (ok: bool, msg: string) {
	dst := bridgesvc.pjoin(data_dir, "extensions")
	if bridge_extension_same_path(src, dst) do return true, "skipped"
	tmp := strings.concatenate({dst, ".new"}, context.temp_allocator)
	bak := strings.concatenate({dst, ".bak"}, context.temp_allocator)
	_ = os.remove_all(tmp)
	if copied, cmsg := bridge_extensions_copy_tree(src, tmp); !copied {
		_ = os.remove_all(tmp)
		return false, cmsg
	}
	_ = os.remove_all(bak)
	if os.exists(dst) {
		if err := os.rename(dst, bak); err != nil {
			_ = os.remove_all(tmp)
			return false, fmt.tprintf("cannot move %s aside: %v", dst, err)
		}
	}
	if err := os.rename(tmp, dst); err != nil {
		if os.exists(bak) && !os.exists(dst) do _ = os.rename(bak, dst)
		return false, fmt.tprintf("cannot install %s: %v", dst, err)
	}
	return true, fmt.tprintf("copied %s to %s", src, dst)
}

bridge_extensions_restore :: proc(data_dir: string) {
	dst := bridgesvc.pjoin(data_dir, "extensions")
	bak := strings.concatenate({dst, ".bak"}, context.temp_allocator)
	if !os.exists(bak) do return
	_ = os.remove_all(dst)
	_ = os.rename(bak, dst)
}

// bridge_extensions_shared_root is the profile-neutral root next to a profile's
// data dir (<data root>/<service>).
bridge_extensions_shared_root :: proc(data_dir: string) -> string {
	return bridgesvc.pjoin(bridgesvc.pdir(strings.trim_right(data_dir, "/\\")), BRIDGE_SHARED_EXTENSIONS_DIR)
}

// bridge_extensions_newest_shared is the extensions dir of the newest release
// published under root, or "".
bridge_extensions_newest_shared :: proc(root: string) -> string {
	infos, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if err != nil do return ""
	best := ""
	for info in infos {
		if !os.is_dir(bridgesvc.pjoin(root, info.name, "extensions")) do continue
		if best == "" || bridge_provider_extension_version_compare(info.name, best) > 0 do best = info.name
	}
	return "" if best == "" else bridgesvc.pjoin(root, best, "extensions")
}

// bridge_extensions_publish_shared publishes a profile's extensions as this
// release's shared copy and returns the newest shared release, so a profile on
// an older Bridge never downgrades what a newer one registered. A published
// release is never rewritten: other profiles may be registered from it.
bridge_extensions_publish_shared :: proc(ext_root, data_dir: string) -> (shared: string, ok: bool, msg: string) {
	root := bridge_extensions_shared_root(data_dir)
	dst := bridgesvc.pjoin(root, contracts.APP_VERSION, "extensions")
	if !os.is_dir(dst) {
		tmp := strings.concatenate({bridgesvc.pdir(dst), ".new"}, context.temp_allocator)
		_ = os.remove_all(tmp)
		if copied, cmsg := bridge_extensions_copy_tree(ext_root, bridgesvc.pjoin(tmp, "extensions")); !copied {
			_ = os.remove_all(tmp)
			return "", false, cmsg
		}
		// A profile installing the same release at the same time may win the rename.
		if err := os.rename(tmp, bridgesvc.pdir(dst)); err != nil && !os.is_dir(dst) {
			_ = os.remove_all(tmp)
			return "", false, fmt.tprintf("cannot publish %s: %v", dst, err)
		}
		_ = os.remove_all(tmp)
	}
	return bridge_extensions_newest_shared(root), true, ""
}

// bridge_extensions_prune_shared removes shared releases older than the one
// at keep (an extensions dir from bridge_extensions_newest_shared). Call it only
// once every provider is registered from keep.
bridge_extensions_prune_shared :: proc(keep: string) {
	release_dir := bridgesvc.pdir(keep)
	root, keep_version := bridgesvc.pdir(release_dir), bridgesvc.pbase(release_dir)
	infos, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if err != nil do return
	for info in infos {
		if strings.has_suffix(info.name, ".new") || !os.is_dir(bridgesvc.pjoin(root, info.name, "extensions")) do continue
		if bridge_provider_extension_version_compare(info.name, keep_version) < 0 do _ = os.remove_all(bridgesvc.pjoin(root, info.name))
	}
}

// bridge_extensions_sync_installed publishes the profile's installed
// <data_dir>/extensions to the shared root and ensures every provider against
// the newest shared release (the profile copy when publishing fails).
bridge_extensions_sync_installed :: proc(data_dir: string, on_line: proc(data: rawptr, line: Bridge_Extension_Sync_Line) = nil, data: rawptr = nil) -> (lines: []Bridge_Extension_Sync_Line, failures: int, note: string) {
	ext_root := bridgesvc.pjoin(data_dir, "extensions")
	shared, published, msg := bridge_extensions_publish_shared(ext_root, data_dir)
	root := shared if published && shared != "" else ext_root
	note = fmt.tprintf("shared %s", shared) if root == shared else fmt.tprintf("profile copy %s (shared root unavailable: %s)", ext_root, msg)
	lines, failures = bridge_extensions_sync_providers(root, on_line, data)
	if root == shared && failures == 0 do bridge_extensions_prune_shared(shared)
	return
}

// bridge_extensions_sync_providers ensures every detected provider against the
// bundle at ext_root. on_line, when set, sees each provider as it finishes.
bridge_extensions_sync_providers :: proc(ext_root: string, on_line: proc(data: rawptr, line: Bridge_Extension_Sync_Line) = nil, data: rawptr = nil) -> (lines: []Bridge_Extension_Sync_Line, failures: int) {
	out := make([dynamic]Bridge_Extension_Sync_Line, context.temp_allocator)
	providers := BRIDGE_EXTENSION_PROVIDERS
	detected := bridge_extension_discover(providers[:])
	defer bridge_provider_paths_destroy_all(&detected)
	for prov in providers {
		bin := ""
		for d in detected {
			if bridge_extension_canonical_provider(d.provider) == prov && d.state == "present" {
				bin = strings.clone(d.resolved_path, context.temp_allocator)
				break
			}
		}
		line := Bridge_Extension_Sync_Line{provider = prov}
		ext := bridgesvc.pjoin(ext_root, bridge_extension_variant_dir(prov))
		switch {
		case bin == "":
			line.ok, line.skipped = true, true
			line.line = fmt.tprintf("%s: CLI not detected, skipped", prov)
		case !os.is_dir(ext):
			line.line = fmt.tprintf("%s: bundle has no %s", prov, ext)
		case:
			// Each provider gets its own budget so one slow CLI cannot starve the rest.
			r := bridge_extension_ensure(prov, ext, bin, time.time_add(time.now(), BRIDGE_EXTENSION_PROVIDER_TIMEOUT), {})
			line.ok = r.ok
			if r.ok {
				line.line = fmt.tprintf("%s: %s %s (found %s)", prov, r.action, r.version, BRIDGE_EXTENSION_CONDITION_NAMES[r.condition])
			} else {
				line.line = fmt.tprintf("%s: failed after self-heal (found %s): %s: %s", prov, BRIDGE_EXTENSION_CONDITION_NAMES[r.condition], r.code, r.message)
			}
		}
		if !line.ok do failures += 1
		append(&out, line)
		if on_line != nil do on_line(data, line)
	}
	return out[:], failures
}

// `ham-bridge extensions sync [--data-dir D] [--source S] [--json-progress]`.
// --source defaults to the bundle next to this binary; without one the
// installed <data dir>/extensions is synced as is.
bridge_extensions_command :: proc(args: []string) -> bool {
	if len(args) < 3 || args[2] != "sync" {
		fmt.eprintln("usage: ham-bridge extensions sync [--data-dir DIR] [--source DIR] [--json-progress]")
		return false
	}
	json_progress := has_flag(args, "--json-progress")
	data_dir := strings.trim_space(option_value(args, "--data-dir", ""))
	if data_dir == "" do data_dir = strings.trim_space(bridge_config.data_dir)
	if data_dir == "" {
		fmt.eprintln("ham-bridge extensions sync: --data-dir is required")
		return false
	}
	source := strings.trim_space(option_value(args, "--source", ""))
	if source == "" {
		exe, _ := os.get_executable_path(context.temp_allocator)
		if exe == "" && len(os.args) > 0 do exe = os.args[0]
		source = bridge_extensions_bundle_source(bridgesvc.pdir(exe))
	}
	emit := proc(json_progress: bool, ev: bridgesvc.Event) {
		if json_progress do fmt.println(bridgesvc.event_json(ev, context.temp_allocator))
		else do fmt.println(ev.message)
	}
	if source != "" {
		ok, msg := bridge_extensions_install_bundle(source, data_dir)
		if !ok {
			emit(json_progress, {step = "extensions", state = "failed", message = msg, attempt = 1})
			return false
		}
		if msg != "skipped" do emit(json_progress, {step = "extensions", state = "progress", message = msg, attempt = 1})
	}
	Ctx :: struct { json_progress: bool }
	ctx := Ctx{json_progress}
	on_line := proc(data: rawptr, line: Bridge_Extension_Sync_Line) {
		c := (^Ctx)(data)
		ev := bridgesvc.Event{step = "extensions", state = "progress", message = line.line, attempt = 1}
		if c.json_progress do fmt.println(bridgesvc.event_json(ev, context.temp_allocator))
		else do fmt.println(line.line)
	}
	_, failures, note := bridge_extensions_sync_installed(data_dir, on_line, &ctx)
	summary := fmt.tprintf("provider extensions synced from %s (%d failed)", note, failures)
	emit(json_progress, {step = "extensions", state = "ok" if failures == 0 else "failed", pct = 100, message = summary, attempt = 1})
	return failures == 0
}
