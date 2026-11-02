package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_codex_own_marketplace_name_is_toml_safe :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("heimdall-bridge-hub-brolabs-ai"), "heimdall-codex-heimdall-bridge-hub-brolabs-ai")
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("Heimdall_Bridge.Two"), "heimdall-codex-heimdall-bridge-two")
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("  "), "")
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("\"]x"), "heimdall-codex-x")
}

@(test)
test_codex_own_launch_args_need_the_installed_plugin :: proc(t: ^testing.T) {
	home := fmt.tprintf("/tmp/heimdall-codex-own-home-%d", time.now()._nsec)
	defer _ = os.remove_all(home)
	mp := "heimdall-codex-bridge-a"
	testing.expect(t, bridge_codex_own_launch_args_for(home, mp) == nil, "no cache: no override")
	testing.expect(t, bridge_codex_own_launch_args_for(home, "") == nil, "no marketplace: no override")

	cache := fmt.tprintf("%s/plugins/cache/%s/heimdall/0.5.30", home, mp)
	testing.expect(t, os.make_directory_all(cache) == nil)
	args := bridge_codex_own_launch_args_for(home, mp)
	testing.expect_value(t, len(args), 4)
	if len(args) == 4 {
		// The shared registration off, this bridge's own on: exactly one load.
		testing.expect_value(t, args[0], "-c")
		testing.expect_value(t, args[1], "plugins.heimdall@heimdall-codex.enabled=false")
		testing.expect_value(t, args[2], "-c")
		testing.expect_value(t, args[3], "plugins.heimdall@heimdall-codex-bridge-a.enabled=true")
	}
	// Another bridge's cache does not count.
	testing.expect(t, bridge_codex_own_launch_args_for(home, "heimdall-codex-bridge-b") == nil)
}

@(test)
test_codex_config_set_plugin_disabled :: proc(t: ^testing.T) {
	id := "heimdall@heimdall-codex-a"
	Case :: struct { name, input, want: string, changed: bool }
	cases := []Case{
		{"enabled-true",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = true\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n",
			true},
		{"already-disabled",
			"[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			"[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			false},
		{"last-table-no-key",
			"model = \"o3\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\n",
			"model = \"o3\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			true},
		{"middle-table-no-key",
			"[plugins.\"heimdall@heimdall-codex-a\"]\n[other]\nx = 1\n",
			"[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n[other]\nx = 1\n",
			true},
		{"missing-table",
			"model = \"o3\"\n",
			"model = \"o3\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			true},
		{"empty", "", "[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n", true},
		{"other-plugin-untouched",
			"[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n",
			"[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			true},
	}
	for c in cases {
		got, changed, ok := bridge_codex_config_set_plugin_disabled(c.input, id)
		testing.expectf(t, ok, "%s: refused", c.name)
		testing.expectf(t, got == c.want, "%s: got %q want %q", c.name, got, c.want)
		testing.expectf(t, changed == c.changed, "%s: changed %v", c.name, changed)
	}
}

@(test)
test_codex_own_write_marketplace_names_this_bridge :: proc(t: ^testing.T) {
	data_dir := fmt.tprintf("/tmp/heimdall-codex-own-data-%d", time.now()._nsec)
	defer _ = os.remove_all(data_dir)
	_, ok, _ := bridge_codex_own_write_marketplace(data_dir, "heimdall-codex-x")
	testing.expect(t, !ok, "no extension copy: nothing registered")

	plugin := fmt.tprintf("%s/extensions/codex/.codex-plugin", data_dir)
	testing.expect(t, os.make_directory_all(plugin) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/plugin.json", plugin), transmute([]byte)string(`{"name":"heimdall","version":"0.5.30"}`)) == nil)
	root, written, msg := bridge_codex_own_write_marketplace(data_dir, "heimdall-codex-x")
	testing.expectf(t, written, "write: %s", msg)
	testing.expect_value(t, root, fmt.tprintf("%s/codex-marketplace", data_dir))
	testing.expect(t, os.exists(fmt.tprintf("%s/codex/.codex-plugin/plugin.json", root)), "plugin copied")
	raw, err := os.read_entire_file(fmt.tprintf("%s/.agents/plugins/marketplace.json", root), context.temp_allocator)
	testing.expect(t, err == nil)
	// Codex parses it like extensions/.agents/plugins/marketplace.json.
	value, jerr := json.parse(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, jerr == nil, "valid JSON: %s", string(raw))
	testing.expect_value(t, string(value.(json.Object)["name"].(json.String)), "heimdall-codex-x")
	plugins, _ := value.(json.Object)["plugins"].(json.Array)
	testing.expect_value(t, len(plugins), 1)
	if len(plugins) == 1 {
		src, _ := plugins[0].(json.Object)["source"].(json.Object)
		testing.expect_value(t, string(src["path"].(json.String)), "./codex")
	}
	// The bridge's own extensions dir keeps the shared marketplace name for
	// per-account provider profiles: it is not modified.
	testing.expect(t, !os.exists(fmt.tprintf("%s/extensions/.agents/plugins/marketplace.json", data_dir)))
}

@(test)
test_codex_own_launch_args_only_for_default_codex :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/heimdall-codex-own-launch-%d", time.now()._nsec)
	defer _ = os.remove_all(root)
	home := fmt.tprintf("%s/codex-home", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/plugins/cache/heimdall-codex-bridge-x/heimdall/0.5.30", home)) == nil)
	saved_home := os.get_env("CODEX_HOME", context.temp_allocator)
	defer {
		if saved_home != "" {
			_ = os.set_env("CODEX_HOME", saved_home)
		} else {
			os.unset_env("CODEX_HOME")
		}
	}
	_ = os.set_env("CODEX_HOME", home)
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_data := bridge_config.data_dir
	defer bridge_config.data_dir = saved_data
	bridge_config.data_dir = fmt.tprintf("%s/bridges/bridge-x", root)

	args := bridge_pty_host_default_profile_args("codex")
	testing.expect_value(t, len(args), 4)
	if len(args) == 4 do testing.expect_value(t, args[3], "plugins.heimdall@heimdall-codex-bridge-x.enabled=true")
	// Claude launch args stay unchanged.
	testing.expect(t, bridge_pty_host_default_profile_args("claude") == nil)
	testing.expect(t, bridge_pty_host_default_profile_args("claude-code") == nil)
	testing.expect(t, bridge_pty_host_default_profile_args("antigravity") == nil)
	// Another bridge (no own plugin installed) keeps the shared release.
	bridge_config.data_dir = fmt.tprintf("%s/bridges/bridge-y", root)
	testing.expect(t, bridge_pty_host_default_profile_args("codex") == nil)
}

@(test)
test_codex_config_set_plugin_disabled_skips_array_lines :: proc(t: ^testing.T) {
	// A multi-line array value inside the table is not a header.
	input := "[plugins.\"heimdall@heimdall-codex-a\"]\ntags = [\n  [\"x\"],\n  [\"y\"]\n]\nenabled = true\n"
	want := "[plugins.\"heimdall@heimdall-codex-a\"]\ntags = [\n  [\"x\"],\n  [\"y\"]\n]\nenabled = false\n"
	got, changed, ok := bridge_codex_config_set_plugin_disabled(input, "heimdall@heimdall-codex-a")
	testing.expectf(t, got == want, "got %q", got)
	testing.expect(t, changed && ok)
}

@(test)
test_codex_config_remove_own_keeps_everything_else :: proc(t: ^testing.T) {
	input := "model = \"o3\"\n\n[marketplaces.heimdall-codex]\nsource = \"/shared\"\n\n[marketplaces.heimdall-codex-a]\nsource_type = \"local\"\nsource = \"/a\"\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n\n[marketplaces.heimdall-codex-b]\nsource = \"/b\"\n"
	want := "model = \"o3\"\n\n[marketplaces.heimdall-codex]\nsource = \"/shared\"\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n\n[marketplaces.heimdall-codex-b]\nsource = \"/b\"\n"
	got, changed, ok := bridge_codex_config_remove_own(input, "heimdall-codex-a")
	testing.expectf(t, got == want, "got %q", got)
	testing.expect(t, changed && ok)
	_, again, _ := bridge_codex_config_remove_own(got, "heimdall-codex-a")
	testing.expect(t, !again, "nothing left to remove")
	// The shared marketplace is never an own one.
	same, shared, _ := bridge_codex_config_remove_own(input, "heimdall-codex")
	testing.expect(t, !shared && same == input)
}

@(private = "file")
codex_own_test_write :: proc(t: ^testing.T, path, text: string) {
	testing.expect(t, os.write_entire_file(path, transmute([]byte)text) == nil, path)
}

@(test)
test_codex_own_heal_drops_only_marketplaces_with_a_deleted_source :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/heimdall-codex-own-heal-%d", time.now()._nsec)
	defer _ = os.remove_all(root)
	home := fmt.tprintf("%s/codex-home", root)
	live := fmt.tprintf("%s/bridge-a/codex-marketplace", root)
	gone := fmt.tprintf("%s/bridge-b/codex-marketplace", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/.agents/plugins", live)) == nil)
	codex_own_test_write(t, fmt.tprintf("%s/.agents/plugins/marketplace.json", live), "{}")
	for mp in ([]string{"heimdall-codex-bridge-a", "heimdall-codex-bridge-b"}) {
		testing.expect(t, os.make_directory_all(fmt.tprintf("%s/plugins/cache/%s/heimdall/0.5.30", home, mp)) == nil)
	}
	config := fmt.tprintf("[marketplaces.heimdall-codex]\nsource = \"/missing-shared\"\n\n[marketplaces.heimdall-codex-bridge-a]\nsource_type = \"local\"\nsource = \"%s\"\n\n[marketplaces.heimdall-codex-bridge-b]\nsource_type = \"local\"\nsource = \"%s\"\n\n[plugins.\"heimdall@heimdall-codex-bridge-a\"]\nenabled = false\n\n[plugins.\"heimdall@heimdall-codex-bridge-b\"]\nenabled = false\n", live, gone)
	codex_own_test_write(t, fmt.tprintf("%s/config.toml", home), config)

	names, sources := bridge_codex_config_own_marketplaces(config)
	testing.expect_value(t, len(names), 2)
	if len(names) == 2 {
		testing.expect_value(t, names[1], "heimdall-codex-bridge-b")
		testing.expect_value(t, sources[1], gone)
	}

	removed, msg := bridge_codex_own_heal(home)
	testing.expect_value(t, removed, 1)
	testing.expect_value(t, msg, "")
	raw, _ := os.read_entire_file(fmt.tprintf("%s/config.toml", home), context.temp_allocator)
	want := fmt.tprintf("[marketplaces.heimdall-codex]\nsource = \"/missing-shared\"\n\n[marketplaces.heimdall-codex-bridge-a]\nsource_type = \"local\"\nsource = \"%s\"\n\n[plugins.\"heimdall@heimdall-codex-bridge-a\"]\nenabled = false\n", live)
	testing.expectf(t, string(raw) == want, "config %q", string(raw))
	testing.expect(t, os.is_dir(fmt.tprintf("%s/plugins/cache/heimdall-codex-bridge-a", home)), "live cache kept")
	testing.expect(t, !os.exists(fmt.tprintf("%s/plugins/cache/heimdall-codex-bridge-b", home)), "stale cache removed")
	again, _ := bridge_codex_own_heal(home)
	testing.expect_value(t, again, 0)
	// No config at all is nothing to heal.
	none, none_msg := bridge_codex_own_heal(fmt.tprintf("%s/no-home", root))
	testing.expect(t, none == 0 && none_msg == "")
}

@(test)
test_codex_own_unregister_for_uninstall :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/heimdall-codex-own-unreg-%d", time.now()._nsec)
	defer _ = os.remove_all(root)
	home := fmt.tprintf("%s/codex-home", root)
	data_dir := fmt.tprintf("%s/heimdall-bridge-b", root)
	own := fmt.tprintf("%s/codex-marketplace", data_dir)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/.agents/plugins", own)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/plugins/cache/heimdall-codex-heimdall-bridge-b/heimdall/1", home)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/plugins/cache/heimdall-codex/heimdall/1", home)) == nil)
	codex_own_test_write(t, fmt.tprintf("%s/config.toml", home), fmt.tprintf("[marketplaces.heimdall-codex-heimdall-bridge-b]\nsource = \"%s\"\n\n[plugins.\"heimdall@heimdall-codex-heimdall-bridge-b\"]\nenabled = false\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n", own))

	ok, msg := bridge_codex_own_unregister_in(home, data_dir)
	testing.expectf(t, ok, "unregister: %s", msg)
	raw, _ := os.read_entire_file(fmt.tprintf("%s/config.toml", home), context.temp_allocator)
	testing.expect_value(t, string(raw), "[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n")
	testing.expect(t, !os.exists(own), "own marketplace copy removed")
	testing.expect(t, !os.exists(fmt.tprintf("%s/plugins/cache/heimdall-codex-heimdall-bridge-b", home)), "own cache removed")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/plugins/cache/heimdall-codex", home)), "shared cache kept")
	// Nothing registered (a second uninstall run, or no CODEX_HOME) is fine.
	again, _ := bridge_codex_own_unregister_in(home, data_dir)
	testing.expect(t, again)
	missing, _ := bridge_codex_own_unregister_in(fmt.tprintf("%s/none", root), data_dir)
	testing.expect(t, missing)
}

// Header detection: each shape that must (or must not) end an owned table.
@(test)
test_codex_config_remove_own_header_shapes :: proc(t: ^testing.T) {
	Case :: struct { name, input, want: string }
	cases := []Case{
		{"spaced-trailing-comment",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[mcp_servers.mine] # my server\ncommand = \"foo\"\n",
			"[mcp_servers.mine] # my server\ncommand = \"foo\"\n"},
		{"array-table",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[[profiles.list]] # first\nname = \"x\"\n",
			"[[profiles.list]] # first\nname = \"x\"\n"},
		{"quoted-key-with-bracket-and-hash",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[projects.\"/home/u/a]b # c\"]\ntrust_level = \"trusted\"\n[projects.'/x]#y'] # z\ntrust_level = \"trusted\"\n",
			"[projects.\"/home/u/a]b # c\"]\ntrust_level = \"trusted\"\n[projects.'/x]#y'] # z\ntrust_level = \"trusted\"\n"},
		{"whitespace",
			"  [ marketplaces . heimdall-codex-a ]  \t# mine\nsource = \"/x\"\n\n\t[ mcp_servers . mine ]\t\ncommand = \"foo\"\n",
			"\t[ mcp_servers . mine ]\t\ncommand = \"foo\"\n"},
	}
	for c in cases {
		got, changed, ok := bridge_codex_config_remove_own(c.input, "heimdall-codex-a")
		testing.expectf(t, ok && changed, "%s: ok %v changed %v", c.name, ok, changed)
		testing.expectf(t, got == c.want, "%s: got %q want %q", c.name, got, c.want)
	}
	// An [[array]] of the same name is not the owned table.
	arr := "[[marketplaces.heimdall-codex-a]]\nsource = \"/x\"\n"
	same, changed, ok := bridge_codex_config_remove_own(arr, "heimdall-codex-a")
	testing.expect(t, ok && !changed && same == arr)
}

// Round trip: removing the own tables from a config that has them gives back the
// config without them byte for byte, and a config without them is left as is.
@(test)
test_codex_config_remove_own_round_trip_corpus :: proc(t: ^testing.T) {
	MP :: "[marketplaces.heimdall-codex-a]\nsource_type = \"local\"\nsource = \"/a\"\n\n"
	PL :: "[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n\n"
	Case :: struct { name, with_own, base: string }
	cases := []Case{
		// The round-3 review repro.
		{"reviewer-repro",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[mcp_servers.mine] # my server\ncommand = \"foo\"\n",
			"[mcp_servers.mine] # my server\ncommand = \"foo\"\n"},
		{"realistic",
			"model = \"gpt-5\"\napproval_policy = \"on-request\"   # comment\n\n[mcp_servers.mine] # my server\ncommand = \"foo\"\nargs = [\n  \"--flag\",\n  [\"nested\"],\n]\n\n" + MP + "# my notes about profiles\n[[profiles.list]]\nname = \"x\"\n\n" + PL + "[projects.\"/home/u/a]b # c\"]\ntrust_level = \"trusted\"\n",
			"model = \"gpt-5\"\napproval_policy = \"on-request\"   # comment\n\n[mcp_servers.mine] # my server\ncommand = \"foo\"\nargs = [\n  \"--flag\",\n  [\"nested\"],\n]\n\n# my notes about profiles\n[[profiles.list]]\nname = \"x\"\n\n[projects.\"/home/u/a]b # c\"]\ntrust_level = \"trusted\"\n"},
		// A header-looking line inside a multi-line string is text, not a table.
		{"multi-line-string",
			"developer_instructions = \"\"\"\n[marketplaces.heimdall-codex-a]\nsource = \"/fake\"\n\"\"\"\nnotes = '''\n[plugins.\"heimdall@heimdall-codex-a\"]\n'''\n\n" + MP + PL,
			"developer_instructions = \"\"\"\n[marketplaces.heimdall-codex-a]\nsource = \"/fake\"\n\"\"\"\nnotes = '''\n[plugins.\"heimdall@heimdall-codex-a\"]\n'''\n"},
		{"crlf",
			"model = \"o3\"\r\n\r\n[marketplaces.heimdall-codex-a]\r\nsource = \"/a\"\r\n\r\n[tui]\r\nnotifications = true\r\n",
			"model = \"o3\"\r\n\r\n[tui]\r\nnotifications = true\r\n"},
		{"no-final-newline",
			"[marketplaces.heimdall-codex-a]\nsource = \"/a\"\n\n[tui]\nnotifications = true",
			"[tui]\nnotifications = true"},
		{"comment-after-own-table-stays",
			MP + "# about mcp\n[mcp_servers.mine]\ncommand = \"foo\"\n",
			"# about mcp\n[mcp_servers.mine]\ncommand = \"foo\"\n"},
		{"only-own", MP + PL, ""},
	}
	for c in cases {
		got, changed, ok := bridge_codex_config_remove_own(c.with_own, "heimdall-codex-a")
		testing.expectf(t, ok && changed, "%s: ok %v changed %v", c.name, ok, changed)
		testing.expectf(t, got == c.base, "%s: got %q want %q", c.name, got, c.base)
		kept, again, again_ok := bridge_codex_config_remove_own(c.base, "heimdall-codex-a")
		testing.expectf(t, again_ok && !again && kept == c.base, "%s: base changed: %q", c.name, kept)
		// Adding the own plugin table only ever appends; every byte before stays.
		added, _, added_ok := bridge_codex_config_set_plugin_disabled(c.base, "heimdall@heimdall-codex-a")
		testing.expectf(t, added_ok && strings.has_prefix(added, c.base), "%s: set_plugin_disabled rewrote other bytes: %q", c.name, added)
	}
}

@(test)
test_codex_config_set_plugin_disabled_stops_at_commented_header :: proc(t: ^testing.T) {
	id := "heimdall@heimdall-codex-a"
	input := "[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = true\n[mcp_servers.mine] # my server\nenabled = true\n"
	got, changed, ok := bridge_codex_config_set_plugin_disabled(input, id)
	testing.expect(t, ok && changed)
	testing.expect_value(t, got, "[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n[mcp_servers.mine] # my server\nenabled = true\n")
	// No enabled key: it goes into the owned table, not the next one.
	input = "[plugins.\"heimdall@heimdall-codex-a\"] # own\n\n[mcp_servers.mine] # my server\nenabled = true\n"
	got, changed, ok = bridge_codex_config_set_plugin_disabled(input, id)
	testing.expect(t, ok && changed)
	testing.expect_value(t, got, "[plugins.\"heimdall@heimdall-codex-a\"] # own\nenabled = false\n\n[mcp_servers.mine] # my server\nenabled = true\n")
	// Already disabled, with a comment: nothing to do.
	input = "[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false # per launch\n"
	got, changed, ok = bridge_codex_config_set_plugin_disabled(input, id)
	testing.expect(t, ok && !changed && got == input)
}

@(test)
test_codex_config_own_marketplaces_stop_at_commented_header :: proc(t: ^testing.T) {
	config := "[marketplaces.heimdall-codex-a] # own\nsource = \"/a\" # src\n[mcp_servers.x] # not a marketplace\nsource = \"/evil\"\n[marketplaces.heimdall-codex-b]\nsource = '/b'\n"
	names, sources := bridge_codex_config_own_marketplaces(config)
	testing.expect_value(t, len(names), 2)
	if len(names) == 2 {
		testing.expect_value(t, names[0], "heimdall-codex-a")
		testing.expect_value(t, sources[0], "/a")
		testing.expect_value(t, names[1], "heimdall-codex-b")
		testing.expect_value(t, sources[1], "/b")
	}
}

// When a line cannot be classified for sure, every edit refuses and the file on
// disk keeps every byte.
@(test)
test_codex_config_edits_refuse_when_unsure :: proc(t: ^testing.T) {
	unsure := []string{
		// An escaped quote in a header key (not decoded).
		"[plugins.\"a\\\"]b\"]\nx = 1\n",
		// Not valid TOML: an unterminated string, an unclosed array.
		"name = \"open\n",
		"args = [\n  \"a\",\n",
	}
	for prefix in unsure {
		input := strings.concatenate({prefix, "\n[marketplaces.heimdall-codex-a]\nsource = \"/a\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = true\n"}, context.temp_allocator)
		got, changed, ok := bridge_codex_config_remove_own(input, "heimdall-codex-a")
		testing.expectf(t, !changed && got == input, "remove_own %q: changed %v", prefix, changed)
		// Inside an unclosed array nothing is a header, so nothing is dropped
		// either way; elsewhere the owned header is found and the edit refuses.
		if prefix != unsure[2] do testing.expectf(t, !ok, "remove_own %q should refuse", prefix)
		got, changed, ok = bridge_codex_config_set_plugin_disabled(input, "heimdall@heimdall-codex-a")
		testing.expectf(t, !ok && !changed && got == input, "set_plugin_disabled %q: ok %v changed %v", prefix, ok, changed)
	}

	root := fmt.tprintf("/tmp/heimdall-codex-own-unsure-%d", time.now()._nsec)
	defer _ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/plugins/cache/heimdall-codex-a/heimdall/1", root)) == nil)
	config := "[plugins.\"a\\\"]b\"]\nx = 1\n\n[marketplaces.heimdall-codex-a]\nsource = \"/a\"\n"
	codex_own_test_write(t, fmt.tprintf("%s/config.toml", root), config)
	ok, msg := bridge_codex_own_unregister_files(root, "heimdall-codex-a")
	testing.expectf(t, !ok && msg != "", "unregister should refuse: %s", msg)
	raw, _ := os.read_entire_file(fmt.tprintf("%s/config.toml", root), context.temp_allocator)
	testing.expect_value(t, string(raw), config)
	testing.expect(t, !os.exists(fmt.tprintf("%s/config.toml.heimdall.tmp", root)), "no tmp left")
}
