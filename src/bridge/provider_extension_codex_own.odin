package main

// Per-bridge Codex extension, loaded per launch (no separate CODEX_HOME).
//
// The OS user's normal Codex config keeps the shared `heimdall@heimdall-codex`
// registration (the newest release of any bridge, see
// provider_extension_reconcile.odin). In addition every bridge profile registers
// its own <data_dir>/extensions/codex under its own marketplace
// `heimdall-codex-<service>`, persisted with `enabled = false`, so neither the
// user's own Codex sessions nor other bridges' agents load it. This bridge's
// agents launch with
//   -c plugins.heimdall@heimdall-codex.enabled=false
//   -c plugins.heimdall@heimdall-codex-<service>.enabled=true
// and so load exactly one Heimdall plugin: their own bridge's version, with the
// shared CODEX_HOME and login. Codex (0.162.0) loads plugins from its versioned
// install cache only for marketplaces persisted in config.toml; `-c` can switch a
// persisted plugin on or off for one launch but cannot add a marketplace or
// repoint one. Codex has no CLI to disable a plugin, so the bridge edits the one
// `[plugins."heimdall@heimdall-codex-<service>"]` table itself.
//
// Everything here is best effort: when the own registration is missing the
// launch passes no override and agents keep the shared release.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"
import cfg_lib "odin_test:lib/config"

BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX :: "heimdall-codex-"
BRIDGE_CODEX_OWN_MARKETPLACE_DIR :: "codex-marketplace"
BRIDGE_CODEX_PLUGIN_NAME :: "heimdall"

Bridge_Codex_Own_Ensure :: proc(bin_path: string, deadline: time.Time, env: []string) -> (ok: bool, msg: string)
Bridge_Codex_Own_Remove :: proc(bin_path: string, deadline: time.Time, env: []string)
Bridge_Codex_Own_Heal :: proc() -> (removed: int, msg: string)
Bridge_Codex_Own_Unregister :: proc(data_dir: string) -> (ok: bool, msg: string)

// Called by bridge_extension_ensure/remove for the default Codex profile and by
// `ham-bridge uninstall`; tests replace these (they would touch the real
// ~/.codex/config.toml).
bridge_codex_own_ensure_hook: Bridge_Codex_Own_Ensure = bridge_codex_own_ensure
bridge_codex_own_remove_hook: Bridge_Codex_Own_Remove = bridge_codex_own_remove
bridge_codex_own_heal_hook: Bridge_Codex_Own_Heal = proc() -> (int, string) { return bridge_codex_own_heal(bridge_codex_default_home()) }
bridge_codex_own_unregister_hook: Bridge_Codex_Own_Unregister = bridge_codex_own_unregister

// bridge_codex_own_marketplace_name_for maps a bridge service name to its
// marketplace name: lower-case letters, digits and '-' only (it is also a TOML
// bare key segment and a cache directory name). "" when nothing is left.
bridge_codex_own_marketplace_name_for :: proc(service: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for ch in strings.to_lower(strings.trim_space(service), context.temp_allocator) {
		switch ch {
		case 'a'..='z', '0'..='9', '-': strings.write_rune(&b, ch)
		case '_', '.', ' ':             strings.write_byte(&b, '-')
		}
	}
	s := strings.trim(strings.to_string(b), "-")
	if s == "" do return ""
	return strings.concatenate({BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX, s}, allocator)
}

bridge_codex_own_data_dir :: proc() -> string {
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do return ""
	return codex_own_expand_home(data_dir, context.temp_allocator)
}

// This bridge's own marketplace name; "" without a data dir.
bridge_codex_own_marketplace_name :: proc() -> string {
	return bridge_codex_own_marketplace_name_for_data_dir(bridge_codex_own_data_dir())
}

// The marketplace name of the profile whose data dir is data_dir (its basename is
// the service name); also used by uninstall, which has no bridge config loaded.
bridge_codex_own_marketplace_name_for_data_dir :: proc(data_dir: string) -> string {
	if data_dir == "" do return ""
	return bridge_codex_own_marketplace_name_for(bridgesvc.pbase(strings.trim_right(data_dir, "/\\")))
}

bridge_codex_own_plugin_id :: proc(marketplace: string) -> string {
	return strings.concatenate({BRIDGE_CODEX_PLUGIN_NAME, "@", marketplace}, context.temp_allocator)
}

// The CODEX_HOME agents of the default profile use: $CODEX_HOME, else ~/.codex.
bridge_codex_default_home :: proc() -> string {
	if env := strings.trim_space(os.get_env("CODEX_HOME", context.temp_allocator)); env != "" do return codex_own_expand_home(env, context.temp_allocator)
	return codex_own_expand_home("~/.codex", context.temp_allocator)
}

// bridge_codex_own_launch_args_for is pure apart from one directory check: the
// per-launch overrides when marketplace's plugin is in codex_home's install
// cache, else nil (the launch keeps the shared release).
bridge_codex_own_launch_args_for :: proc(codex_home, marketplace: string, allocator := context.temp_allocator) -> []string {
	if codex_home == "" || marketplace == "" do return nil
	cache := bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(codex_home, "plugins"), "cache"), bridgesvc.pjoin(marketplace, BRIDGE_CODEX_PLUGIN_NAME))
	if !os.is_dir(cache) do return nil
	args := make([]string, 4, allocator)
	args[0] = "-c"
	args[1] = strings.concatenate({"plugins.", BRIDGE_CODEX_PLUGIN_ID, ".enabled=false"}, allocator)
	args[2] = "-c"
	args[3] = strings.concatenate({"plugins.", BRIDGE_CODEX_PLUGIN_NAME, "@", marketplace, ".enabled=true"}, allocator)
	return args
}

// Overrides for a launch of the default Codex profile (no provider profile).
bridge_codex_own_launch_args :: proc(allocator := context.temp_allocator) -> []string {
	return bridge_codex_own_launch_args_for(bridge_codex_default_home(), bridge_codex_own_marketplace_name(), allocator)
}

// config.toml is the user's own file and Codex has no CLI to edit it, so the
// bridge edits it as text. codex_toml_scan finds table headers the way a TOML
// parser would (never inside a multi-line string or array; trailing comments,
// quoted keys and [[array]] tables understood), every edit changes only the lines
// of the table it owns, and a line the scan cannot classify for sure makes the
// edit refuse (ok = false) rather than guess.

Codex_Toml_Line_Kind :: enum {
	Content,
	Header,
	Unclear,
}

Codex_Toml_Line :: struct {
	start, end: int, // byte range in the config; end includes the '\n'
	kind:       Codex_Toml_Line_Kind,
	array:      bool,     // a [[array]] header
	name:       []string, // a header's decoded key segments
	top:        bool,     // starts outside any multi-line string or array
	blank:      bool,
	comment:    bool,
}

Codex_Toml_Scan :: struct {
	lines: [dynamic]Codex_Toml_Line,
	clean: bool, // no Unclear line and nothing left open at the end
}

@(private = "file")
codex_toml_scan :: proc(config: string) -> (scan: Codex_Toml_Scan) {
	scan.lines = make([dynamic]Codex_Toml_Line, context.temp_allocator)
	scan.clean = true
	ml: u8 // the quote of an open multi-line string, else 0
	depth := 0 // open '[' / '{' of a value
	for start := 0; start < len(config); {
		end := len(config)
		if nl := strings.index_byte(config[start:], '\n'); nl >= 0 do end = start + nl + 1
		text := strings.trim_space(config[start:end])
		line := Codex_Toml_Line{start = start, end = end, top = ml == 0 && depth == 0, blank = text == ""}
		line.comment = line.top && strings.has_prefix(text, "#")
		if line.top && strings.has_prefix(text, "[") {
			if name, array, ok := codex_toml_parse_header(text); ok {
				line.kind, line.name, line.array = .Header, name, array
			} else {
				line.kind = .Unclear
			}
		} else if !codex_toml_scan_values(text, &ml, &depth) {
			line.kind = .Unclear
		}
		if line.kind == .Unclear do scan.clean = false
		append(&scan.lines, line)
		start = end
	}
	if ml != 0 || depth != 0 do scan.clean = false
	return
}

// codex_toml_scan_values follows strings, comments and brackets of one non-header
// line, carrying an open multi-line string or array to the next line. false for
// a line that is not valid TOML.
@(private = "file")
codex_toml_scan_values :: proc(text: string, ml: ^u8, depth: ^int) -> bool {
	for i := 0; i < len(text); {
		ch := text[i]
		if ml^ != 0 {
			if ml^ == '"' && ch == '\\' {
				i += 2
				continue
			}
			if ch != ml^ {
				i += 1
				continue
			}
			run := 0
			for i + run < len(text) && text[i + run] == ml^ do run += 1
			// Up to two quotes of content may come right before the closing three.
			if run > 5 do return false
			if run >= 3 do ml^ = 0
			i += run
			continue
		}
		switch ch {
		case '#':
			return true
		case '"', '\'':
			if strings.has_prefix(text[i:], `"""`) || strings.has_prefix(text[i:], "'''") {
				ml^ = ch
				i += 3
				continue
			}
			j := i + 1
			for j < len(text) && text[j] != ch {
				if ch == '"' && text[j] == '\\' do j += 1
				j += 1
			}
			if j >= len(text) do return false
			i = j
		case '[', '{':
			depth^ += 1
		case ']', '}':
			depth^ -= 1
			if depth^ < 0 do return false
		}
		i += 1
	}
	return true
}

// codex_toml_parse_header parses a `[a."b".c]` or `[[a]]` line, optionally
// followed by a comment.
@(private = "file")
codex_toml_parse_header :: proc(text: string) -> (name: []string, array, ok: bool) {
	array = strings.has_prefix(text, "[[")
	key, next, key_ok := codex_toml_parse_key(text, 2 if array else 1)
	if !key_ok do return nil, false, false
	close := "]]" if array else "]"
	if !strings.has_prefix(text[next:], close) do return nil, false, false
	rest := strings.trim_space(text[next + len(close):])
	if rest != "" && rest[0] != '#' do return nil, false, false
	return key, array, true
}

// codex_toml_parse_key reads a dotted key from text[from:]; next is the first
// byte after it and its trailing whitespace.
@(private = "file")
codex_toml_parse_key :: proc(text: string, from: int) -> (key: []string, next: int, ok: bool) {
	segs := make([dynamic]string, context.temp_allocator)
	i := from
	for {
		for i < len(text) && (text[i] == ' ' || text[i] == '\t') do i += 1
		if i >= len(text) do return nil, 0, false
		switch text[i] {
		case '"', '\'':
			j := strings.index_byte(text[i + 1:], text[i])
			if j < 0 do return nil, 0, false
			seg := text[i + 1:i + 1 + j]
			// Escapes would need decoding; Heimdall never writes them in a key.
			if text[i] == '"' && strings.contains_rune(seg, '\\') do return nil, 0, false
			append(&segs, seg)
			i += j + 2
		case:
			j := i
			for j < len(text) && codex_toml_is_bare(text[j]) do j += 1
			if j == i do return nil, 0, false
			append(&segs, text[i:j])
			i = j
		}
		for i < len(text) && (text[i] == ' ' || text[i] == '\t') do i += 1
		if i < len(text) && text[i] == '.' {
			i += 1
			continue
		}
		return segs[:], i, true
	}
}

@(private = "file")
codex_toml_is_bare :: proc(ch: u8) -> bool {
	switch ch {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '-':
		return true
	}
	return false
}

// codex_toml_key_value splits a top-level `key = value` line.
@(private = "file")
codex_toml_key_value :: proc(text: string) -> (key: []string, value: string, ok: bool) {
	k, next, key_ok := codex_toml_parse_key(text, 0)
	if !key_ok || next >= len(text) || text[next] != '=' do return nil, "", false
	return k, text[next + 1:], true
}

// codex_toml_scalar decodes a one-line value: a string without escapes, or a bare
// value (a bool, a number) up to a comment.
@(private = "file")
codex_toml_scalar :: proc(value: string) -> (s: string, ok: bool) {
	v := strings.trim_space(value)
	if v == "" do return "", false
	if v[0] == '"' || v[0] == '\'' {
		if strings.has_prefix(v, `"""`) || strings.has_prefix(v, "'''") do return "", false
		j := strings.index_byte(v[1:], v[0])
		if j < 0 do return "", false
		s = v[1:1 + j]
		if v[0] == '"' && strings.contains_rune(s, '\\') do return "", false
		rest := strings.trim_space(v[j + 2:])
		return s, rest == "" || rest[0] == '#'
	}
	if hash := strings.index_byte(v, '#'); hash >= 0 do v = strings.trim_space(v[:hash])
	return v, v != ""
}

@(private = "file")
codex_toml_name_is :: proc(name: []string, table, key: string) -> bool {
	return len(name) == 2 && name[0] == table && name[1] == key
}

// codex_toml_table_end is the index of the line after header h's table.
@(private = "file")
codex_toml_table_end :: proc(lines: []Codex_Toml_Line, h: int) -> int {
	next := h + 1
	for next < len(lines) && lines[next].kind != .Header do next += 1
	return next
}

// bridge_codex_config_set_plugin_disabled returns config (config.toml text) with
// `enabled = false` in the `[plugins."<plugin_id>"]` table, adding the key or the
// table when missing; nothing else changes. changed is false when it already
// says so; ok is false (config returned as is) when config cannot be edited
// safely.
bridge_codex_config_set_plugin_disabled :: proc(config, plugin_id: string, allocator := context.temp_allocator) -> (out: string, changed, ok: bool) {
	scan := codex_toml_scan(config)
	if !scan.clean do return config, false, false
	lines := scan.lines[:]
	header := -1
	for line, h in lines {
		if line.kind != .Header || line.array || !codex_toml_name_is(line.name, "plugins", plugin_id) do continue
		// Defined twice is not valid TOML.
		if header >= 0 do return config, false, false
		header = h
	}
	if header < 0 {
		sep := "" if config == "" || strings.has_suffix(config, "\n\n") else ("\n" if strings.has_suffix(config, "\n") else "\n\n")
		return strings.concatenate({config, sep, "[plugins.\"", plugin_id, "\"]\nenabled = false\n"}, allocator), true, true
	}
	// Without an enabled key it goes after the table's last value line.
	insert_at := lines[header].end
	for line in lines[header + 1:codex_toml_table_end(lines, header)] {
		if line.blank || line.comment do continue
		insert_at = line.end
		if !line.top do continue
		key, value, kv := codex_toml_key_value(strings.trim_space(config[line.start:line.end]))
		if !kv do return config, false, false
		if len(key) != 1 || key[0] != "enabled" do continue
		v, scalar := codex_toml_scalar(value)
		if !scalar do return config, false, false
		if v == "false" do return config, false, true
		// Replace the line, keeping its line ending.
		text_end := line.end
		if text_end > line.start && config[text_end - 1] == '\n' do text_end -= 1
		if text_end > line.start && config[text_end - 1] == '\r' do text_end -= 1
		return strings.concatenate({config[:line.start], "enabled = false", config[text_end:]}, allocator), true, true
	}
	nl := "" if insert_at > 0 && config[insert_at - 1] == '\n' else "\n"
	return strings.concatenate({config[:insert_at], nl, "enabled = false\n", config[insert_at:]}, allocator), true, true
}

bridge_codex_config_disable_plugin :: proc(codex_home, plugin_id: string) -> (ok: bool, msg: string) {
	path := bridgesvc.pjoin(codex_home, "config.toml")
	if !os.exists(path) do return false, fmt.tprintf("cannot read %s: missing", path)
	return bridge_codex_config_rewrite(codex_home, bridge_codex_config_set_plugin_disabled, plugin_id)
}

// bridge_codex_config_remove_own returns config without the
// `[marketplaces.<marketplace>]` and `[plugins."heimdall@<marketplace>"]` tables
// of a `heimdall-codex-*` marketplace only; every other byte is kept. A table
// goes from its header through its last value line plus the blank lines after
// it (its separator); a comment after its last value may belong to the next
// table and stays. changed is false when neither is there; ok is false (config
// returned as is) when config cannot be edited safely.
bridge_codex_config_remove_own :: proc(config, marketplace: string, allocator := context.temp_allocator) -> (out: string, changed, ok: bool) {
	// Only ever a bridge's own marketplace, never the shared heimdall-codex.
	if !strings.has_prefix(marketplace, BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX) do return config, false, true
	plugin_id := bridge_codex_own_plugin_id(marketplace)
	scan := codex_toml_scan(config)
	lines := scan.lines[:]
	drop := make([]bool, len(lines), context.temp_allocator)
	for line, h in lines {
		if line.kind != .Header || line.array do continue
		if !codex_toml_name_is(line.name, "marketplaces", marketplace) && !codex_toml_name_is(line.name, "plugins", plugin_id) do continue
		if !scan.clean do return config, false, false
		changed = true
		end := codex_toml_table_end(lines, h)
		last := h
		for k in h + 1 ..< end {
			if !lines[k].blank && !lines[k].comment do last = k
		}
		for last + 1 < end && lines[last + 1].blank do last += 1
		for k in h ..= last do drop[k] = true
	}
	if !changed do return config, false, true
	// A table dropped at the end of the file takes the blank lines before it.
	if drop[len(drop) - 1] {
		k := len(drop) - 1
		for k >= 0 && drop[k] do k -= 1
		for k >= 0 && lines[k].blank {
			drop[k] = true
			k -= 1
		}
	}
	b := strings.builder_make(allocator)
	for line, k in lines {
		if !drop[k] do strings.write_string(&b, config[line.start:line.end])
	}
	return strings.to_string(b), true, true
}

// bridge_codex_config_own_marketplaces lists every `heimdall-codex-*` marketplace
// (any bridge's own) in config with its `source`.
bridge_codex_config_own_marketplaces :: proc(config: string, allocator := context.temp_allocator) -> (names, sources: [dynamic]string) {
	names = make([dynamic]string, allocator)
	sources = make([dynamic]string, allocator)
	current := -1
	for line in codex_toml_scan(config).lines {
		switch line.kind {
		case .Header:
			current = -1
			if !line.array && len(line.name) == 2 && line.name[0] == "marketplaces" && strings.has_prefix(line.name[1], BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX) {
				append(&names, strings.clone(line.name[1], allocator))
				append(&sources, "")
				current = len(names) - 1
			}
			continue
		case .Unclear:
			// Possibly a header: the table it would end is no longer known.
			current = -1
			continue
		case .Content:
		}
		if current < 0 || !line.top || line.blank || line.comment do continue
		key, value, kv := codex_toml_key_value(strings.trim_space(config[line.start:line.end]))
		if !kv || len(key) != 1 || key[0] != "source" do continue
		if source, scalar := codex_toml_scalar(value); scalar do sources[current] = strings.clone(source, allocator)
	}
	return
}

// bridge_codex_config_rewrite applies edit to $codex_home/config.toml atomically
// (tmp + rename). A missing config is nothing to do; one edit cannot change
// safely is left as it is and reported.
@(private = "file")
bridge_codex_config_rewrite :: proc(codex_home: string, edit: proc(config, arg: string, allocator := context.temp_allocator) -> (string, bool, bool), arg: string) -> (ok: bool, msg: string) {
	path := bridgesvc.pjoin(codex_home, "config.toml")
	if !os.exists(path) do return true, ""
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false, fmt.tprintf("cannot read %s: %v", path, err)
	out, changed, safe := edit(string(raw), arg)
	if !safe do return false, fmt.tprintf("left %s unchanged: cannot tell its tables apart for sure", path)
	if !changed do return true, ""
	tmp := strings.concatenate({path, ".heimdall.tmp"}, context.temp_allocator)
	if werr := os.write_entire_file(tmp, transmute([]byte)out); werr != nil do return false, fmt.tprintf("cannot write %s: %v", tmp, werr)
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return false, fmt.tprintf("cannot replace %s: %v", path, rerr)
	}
	return true, ""
}

// bridge_codex_own_unregister_files drops marketplace's tables from
// $codex_home/config.toml and its install cache, without the codex CLI (which may
// be missing from an uninstall's PATH). What `codex plugin remove` and
// `codex plugin marketplace remove` would leave is the same.
bridge_codex_own_unregister_files :: proc(codex_home, marketplace: string) -> (ok: bool, msg: string) {
	if codex_home == "" || !strings.has_prefix(marketplace, BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX) do return true, ""
	if ok, msg = bridge_codex_config_rewrite(codex_home, bridge_codex_config_remove_own, marketplace); !ok do return
	cache := bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(codex_home, "plugins"), "cache"), marketplace)
	_ = os.remove_all(cache)
	if os.exists(cache) do return false, fmt.tprintf("cannot remove %s", cache)
	return true, ""
}

// bridge_codex_own_marketplace_root_ok reports whether source still holds the
// marketplace manifest Codex needs; a deleted one (a bridge uninstalled before
// it cleaned up) makes `codex plugin list` fail for every caller.
bridge_codex_own_marketplace_root_ok :: proc(source: string) -> bool {
	return source != "" && os.is_file(bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(source, ".agents"), "plugins"), "marketplace.json"))
}

// bridge_codex_own_heal unregisters every bridge's own marketplace whose source
// is gone from codex_home. Returns how many it removed.
bridge_codex_own_heal :: proc(codex_home: string) -> (removed: int, msg: string) {
	raw, err := os.read_entire_file(bridgesvc.pjoin(codex_home, "config.toml"), context.temp_allocator)
	if err != nil do return 0, ""
	names, sources := bridge_codex_config_own_marketplaces(string(raw))
	failed := make([dynamic]string, context.temp_allocator)
	for name, i in names {
		if bridge_codex_own_marketplace_root_ok(sources[i]) do continue
		if ok, fail := bridge_codex_own_unregister_files(codex_home, name); ok do removed += 1
		else do append(&failed, fail)
	}
	return removed, strings.join(failed[:], "; ", context.temp_allocator)
}

// bridge_codex_own_write_marketplace lays out <data_dir>/codex-marketplace: a
// copy of <data_dir>/extensions/codex under codex/ and a marketplace manifest
// naming marketplace. A copy, not the extensions dir itself, because a
// per-account provider profile registers that dir under the shared name.
bridge_codex_own_write_marketplace :: proc(data_dir, marketplace: string) -> (root: string, ok: bool, msg: string) {
	src := bridgesvc.pjoin(bridgesvc.pjoin(data_dir, "extensions"), "codex")
	if !os.is_dir(src) do return "", false, fmt.tprintf("no bridge extension copy at %s", src)
	root = bridgesvc.pjoin(data_dir, BRIDGE_CODEX_OWN_MARKETPLACE_DIR)
	_ = os.remove_all(root)
	if copied, copy_msg := bridge_extensions_copy_tree(src, bridgesvc.pjoin(root, "codex")); !copied do return "", false, copy_msg
	mp_dir := bridgesvc.pjoin(bridgesvc.pjoin(root, ".agents"), "plugins")
	if err := os.make_directory_all(mp_dir); err != nil && !os.is_dir(mp_dir) do return "", false, fmt.tprintf("cannot create %s: %v", mp_dir, err)
	// Not fmt: it reads '{' as an argument index.
	manifest := strings.concatenate({
		"{\n  \"name\": \"", marketplace, "\",\n",
		"  \"interface\": {\n    \"displayName\": \"Heimdall Codex (this bridge)\"\n  },\n",
		"  \"plugins\": [\n    {\n      \"name\": \"", BRIDGE_CODEX_PLUGIN_NAME, "\",\n",
		"      \"source\": {\n        \"source\": \"local\",\n        \"path\": \"./codex\"\n      },\n",
		"      \"policy\": {\n        \"installation\": \"AVAILABLE\",\n        \"authentication\": \"ON_INSTALL\"\n      },\n",
		"      \"category\": \"Productivity\"\n    }\n  ]\n}\n",
	}, context.temp_allocator)
	mp_path := bridgesvc.pjoin(mp_dir, "marketplace.json")
	if err := os.write_entire_file(mp_path, transmute([]byte)manifest); err != nil do return "", false, fmt.tprintf("cannot write %s: %v", mp_path, err)
	return root, true, ""
}

// bridge_codex_own_ensure (re)registers this bridge's own Codex plugin from its
// current <data_dir>/extensions copy and persists it disabled. Re-adding on every
// ensure picks up the copy an update just installed (the cache is versioned).
bridge_codex_own_ensure :: proc(bin_path: string, deadline: time.Time, env: []string) -> (ok: bool, msg: string) {
	data_dir := bridge_codex_own_data_dir()
	marketplace := bridge_codex_own_marketplace_name()
	if data_dir == "" || marketplace == "" do return false, "no bridge data dir"
	plugin_id := bridge_codex_own_plugin_id(marketplace)
	codex_home := bridge_codex_default_home()
	// Already installed at this version and disabled: leave it, so that agents
	// launching meanwhile (Hub reconnects ensure again) keep their override.
	version := bridge_provider_extension_read_manifest_version(bridgesvc.pjoin(bridgesvc.pjoin(data_dir, "extensions"), "codex"), "codex")
	cached := bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(codex_home, "plugins"), "cache"), marketplace), bridgesvc.pjoin(BRIDGE_CODEX_PLUGIN_NAME, version))
	if version != "" && os.is_dir(cached) {
		if raw, err := os.read_entire_file(bridgesvc.pjoin(codex_home, "config.toml"), context.temp_allocator); err == nil {
			if _, changed, safe := bridge_codex_config_set_plugin_disabled(string(raw), plugin_id); safe && !changed {
				return true, fmt.tprintf("%s %s is already registered (enabled per launch)", plugin_id, version)
			}
		}
	}
	root, written, write_msg := bridge_codex_own_write_marketplace(data_dir, marketplace)
	if !written do return false, write_msg
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "remove", plugin_id}, deadline, env)
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", marketplace}, deadline, env)
	if _, add_msg, added := bridge_extension_install_step({bin_path, "plugin", "marketplace", "add", root}, deadline, env); !added {
		return false, fmt.tprintf("codex plugin marketplace add %s: %s", root, add_msg)
	}
	if _, add_msg, added := bridge_extension_install_step({bin_path, "plugin", "add", plugin_id}, deadline, env); !added {
		return false, fmt.tprintf("codex plugin add %s: %s", plugin_id, add_msg)
	}
	if disabled, disable_msg := bridge_codex_config_disable_plugin(codex_home, plugin_id); !disabled {
		// Enabled for every Codex session would load it next to the shared one.
		_, _, _ = bridge_extension_install_step({bin_path, "plugin", "remove", plugin_id}, deadline, env)
		_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", marketplace}, deadline, env)
		return false, disable_msg
	}
	return true, fmt.tprintf("registered %s from %s (enabled per launch)", plugin_id, root)
}

// bridge_codex_own_remove drops this bridge's own plugin, marketplace and copy.
// Other bridges' registrations are never touched.
bridge_codex_own_remove :: proc(bin_path: string, deadline: time.Time, env: []string) {
	marketplace := bridge_codex_own_marketplace_name()
	if marketplace == "" do return
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "remove", bridge_codex_own_plugin_id(marketplace)}, deadline, env)
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", marketplace}, deadline, env)
	if data_dir := bridge_codex_own_data_dir(); data_dir != "" do _ = os.remove_all(bridgesvc.pjoin(data_dir, BRIDGE_CODEX_OWN_MARKETPLACE_DIR))
}

// bridge_codex_own_unregister is uninstall's cleanup for the profile whose data
// dir is data_dir: its marketplace and plugin leave the default CODEX_HOME before
// <data_dir>/codex-marketplace goes, so Codex never points at a deleted source.
bridge_codex_own_unregister :: proc(data_dir: string) -> (ok: bool, msg: string) {
	return bridge_codex_own_unregister_in(bridge_codex_default_home(), data_dir)
}

bridge_codex_own_unregister_in :: proc(codex_home, data_dir: string) -> (ok: bool, msg: string) {
	marketplace := bridge_codex_own_marketplace_name_for_data_dir(data_dir)
	if marketplace == "" do return true, ""
	if ok, msg = bridge_codex_own_unregister_files(codex_home, marketplace); !ok do return
	_ = os.remove_all(bridgesvc.pjoin(data_dir, BRIDGE_CODEX_OWN_MARKETPLACE_DIR))
	return true, ""
}

@(private = "file")
codex_own_expand_home :: proc(path: string, allocator := context.temp_allocator) -> string {
	if strings.has_prefix(path, "~/") {
		home := cfg_lib.home_dir()
		defer delete(home)
		if home != "" do return strings.concatenate({home, path[1:]}, allocator)
	}
	return strings.clone(path, allocator)
}
