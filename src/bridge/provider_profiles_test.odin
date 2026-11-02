package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import vault "odin_test:lib/vault"

// REQ-PROF-1, 2, 4: provider profile store, validation and env layering. The tests
// share the store globals, so each holds g_profile_test_mu for its whole run.

g_profile_test_mu: sync.Mutex
@(private = "file")
g_profile_test_seq: int
// Package-level so the slice outlives profile_test_setup (a slice literal would not).
@(private = "file")
PROFILE_TEST_CATALOG := [?]string{"claude", "codex", "pi", "copilot", "antigravity"}

@(private = "file")
profile_test_setup :: proc(t: ^testing.T) -> string {
	sync.mutex_lock(&g_profile_test_mu)
	dir := strings.concatenate(
		{
			os.get_env("TMPDIR", context.temp_allocator) if os.get_env("TMPDIR", context.temp_allocator) != "" else "/tmp",
			"/ham-profile-test-",
			random_hex_string_temp(8),
		},
		context.temp_allocator,
	)
	g_profile_test_seq += 1
	dir = strings.concatenate({dir, "-", random_hex_string_temp(4), "-"}, context.temp_allocator)
	dir = fmt.tprintf("%s%d-%d", dir, os.get_pid(), g_profile_test_seq)
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir, {.Read_User, .Write_User, .Execute_User}) == nil)
	g_profile_test_store_path = strings.concatenate(
		{dir, "/provider_profiles.json"},
		context.temp_allocator,
	)
	g_profile_test_catalog = PROFILE_TEST_CATALOG[:]
	return dir
}

@(private = "file")
profile_test_teardown :: proc(dir: string) {
	_ = os.remove_all(dir)
	g_profile_test_store_path = ""
	g_profile_test_catalog = nil
	sync.mutex_unlock(&g_profile_test_mu)
}

@(private = "file")
random_hex_string_temp :: proc(n: int) -> string {
	buf := make([]byte, n, context.temp_allocator)
	digits := "0123456789abcdef"
	seed := int(profile_now_ms()) + int(uintptr(raw_data(buf)))
	for i in 0 ..< n do buf[i] = digits[(seed + i * 31) % 16]
	return string(buf)
}

@(test)
test_profile_id_namespace_and_metadata :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	ok_p := Provider_Profile {
		profile_id = "claude_k3fq",
		provider   = "claude",
		enabled    = true,
		accent     = "#a1B2c3",
	}
	testing.expect_value(t, profile_validate_metadata(&ok_p), Profile_Error.None)
	def := Provider_Profile {
		profile_id = "claude",
		provider   = "claude",
	}
	testing.expect_value(t, profile_validate_metadata(&def), Profile_Error.None)
	// A custom profile may never take any catalog slug.
	clash := Provider_Profile {
		profile_id = "codex",
		provider   = "claude",
	}
	testing.expect_value(t, profile_validate_metadata(&clash), Profile_Error.Reserved_Id)
	for bad in ([]string{"", "Claude", "1abc", "a b", "abcdefghijklmnopqrstuvwxyz0123456", "a.b"}) {
		p := Provider_Profile {
			profile_id = bad,
			provider   = "claude",
		}
		testing.expectf(t, profile_validate_metadata(&p) == .Invalid_Id, "id %q accepted", bad)
	}
	unknown := Provider_Profile {
		profile_id = "x_1",
		provider   = "nope",
	}
	testing.expect_value(t, profile_validate_metadata(&unknown), Profile_Error.Unknown_Provider)
	accent := Provider_Profile {
		profile_id = "x_1",
		provider   = "claude",
		accent     = "red",
	}
	testing.expect_value(t, profile_validate_metadata(&accent), Profile_Error.Invalid_Accent)
	label := Provider_Profile {
		profile_id = "x_1",
		provider   = "claude",
		label_enc  = "Work",
	}
	testing.expect_value(t, profile_validate_metadata(&label), Profile_Error.Invalid_Label)
}


@(test)
test_profile_driver_validation :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile {
		provider = "claude",
		config = Provider_Profile_Config{config_dir = "/abs/cfg", launch_args = "--chrome"},
		environment = []Provider_Profile_Env{{name = "ANTHROPIC_BASE_URL", value = "x"}},
	}
	testing.expect_value(t, profile_validate(&p), Profile_Error.None)
	p.config.config_dir = "rel/cfg"
	testing.expect_value(t, profile_validate(&p), Profile_Error.Path_Invalid)
	p.config.config_dir = "/abs/cfg"
	p.provider = "copilot"
	testing.expect_value(t, profile_validate(&p), Profile_Error.Config_Dir_Unsupported)
	p = Provider_Profile {
		provider = "claude",
		config = Provider_Profile_Config{home_path = "/abs/codex"},
	}
	testing.expect_value(t, profile_validate(&p), Profile_Error.Config_Invalid)
	p = Provider_Profile {
		provider = "codex",
		config = Provider_Profile_Config{api_key = "key"},
	}
	testing.expect_value(t, profile_validate(&p), Profile_Error.Config_Invalid)
	p = Provider_Profile {
		provider = "claude",
		config = Provider_Profile_Config{binary_path = "/nonexistent/claude"},
	}
	testing.expect_value(t, profile_validate(&p), Profile_Error.Binary_Invalid)
	p.config.binary_path = "claude"
	testing.expect_value(t, profile_validate(&p), Profile_Error.None)
	for name in ([]string{"HOME", "USERPROFILE", "HEIMDALL_AGENT_TOKEN", "heimdall_agent_token"}) {
		p.environment = []Provider_Profile_Env{{name = name, value = "x"}}
		testing.expect_value(t, profile_validate(&p), Profile_Error.Env_Forbidden)
	}
	for env in ([][]Provider_Profile_Env{{{name = "1BAD", value = "x"}}, {{name = "DUP", value = "1"}, {name = "DUP", value = "2"}}, {{name = "BAD", value = "a\x00b"}}}) {
		p.environment = env
		testing.expect_value(t, profile_validate(&p), Profile_Error.Env_Invalid)
	}
	p = Provider_Profile {
		provider = "antigravity",
		config = Provider_Profile_Config{auth_method = "bad"},
	}
	testing.expect_value(t, profile_validate(&p), Profile_Error.Config_Invalid)
	p.config.auth_method = "gemini-api-key"
	testing.expect_value(t, profile_validate(&p), Profile_Error.None)
	p.config.launch_args = "--bad"
	testing.expect_value(t, profile_validate(&p), Profile_Error.Config_Invalid)
}

@(test)
test_profile_env_plan_order :: proc(t: ^testing.T) {
	p := Provider_Profile {
		provider = "claude",
		config = Provider_Profile_Config{config_dir = "/p/config"},
		environment = []Provider_Profile_Env {
			{name = "CLAUDE_CONFIG_DIR", value = "/env/config"},
			{name = "FOO", value = "bar"},
		},
	}
	env := profile_apply_env_plan(
		[]string {
			"HOME=/bridge/home",
			"XDG_CONFIG_HOME=/bridge/.config",
			"CLAUDE_CONFIG_DIR=/base",
			"FOO=old",
			"PATH=/bin",
		},
		profile_env_plan(&p),
	)
	joined := strings.join(env, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "HOME=/bridge/home"))
	testing.expect(t, strings.contains(joined, "XDG_CONFIG_HOME=/bridge/.config"))
	testing.expect(
		t,
		strings.contains(joined, "CLAUDE_CONFIG_DIR=/p/config") &&
		!strings.contains(joined, "/env/config") &&
		!strings.contains(joined, "/base"),
	)
	testing.expect(
		t,
		strings.contains(joined, "FOO=bar") &&
		!strings.contains(joined, "FOO=old") &&
		strings.contains(joined, "PATH=/bin"),
	)
	p = Provider_Profile {
		provider = "codex",
		config = Provider_Profile_Config{home_path = "/codex", shadow_home_path = "/shadow"},
		environment = []Provider_Profile_Env{{name = "CODEX_HOME", value = "/env"}},
	}
	cenv := strings.join(
		profile_apply_env_plan([]string{"CODEX_HOME=/base", "HOME=/bridge"}, profile_env_plan(&p)),
		"\n",
		context.temp_allocator,
	)
	testing.expect(
		t,
		strings.contains(cenv, "CODEX_HOME=/shadow") &&
		!strings.contains(cenv, "/base") &&
		!strings.contains(cenv, "/env"),
	)
	testing.expect(t, strings.contains(cenv, "HOME=/bridge"))
}

@(test)
test_profile_launch_args_t3code_quotes_and_no_expansion :: proc(t: ^testing.T) {
	input := `--config model=\"gpt-6.1-sol\" --prompt don\'t --enable foo\ bar --config=profile='work profile' --path C:\Users\me --quoted "quoted=C:\Users\me" "$HOME" '$(touch nope)' ""`
	args := profile_tokenize_args(input)
	expected := []string {
		"--config",
		"model=\"gpt-6.1-sol\"",
		"--prompt",
		"don't",
		"--enable",
		"foo bar",
		"--config=profile=work profile",
		"--path",
		`C:\Users\me`,
		"--quoted",
		`quoted=C:\Users\me`,
		"$HOME",
		"$(touch nope)",
	}
	testing.expect_value(t, len(args), len(expected))
	for a, i in args do if i < len(expected) - 1 do testing.expect_value(t, a, expected[i])
}

@(test)
test_profile_store_separate_secrets_and_keep :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	cfg := strings.concatenate({dir, "/cfg-work"}, context.temp_allocator)
	p := Provider_Profile {
		profile_id = "claude_w",
		provider = "claude",
		enabled = true,
		config = Provider_Profile_Config {
			config_dir = cfg,
			launch_args = "--chrome",
			custom_models = []string{"local-model"},
		},
		environment = []Provider_Profile_Env {
			{name = "API_KEY", value = "s3cret-value", sensitive = true},
			{name = "PLAIN", value = "v"},
		},
	}
	testing.expect_value(t, profile_upsert(&p, nil, 1000), Profile_Error.None)
	testing.expect(t, os.is_dir(cfg))
	raw, _ := os.read_entire_file(g_profile_test_store_path, context.temp_allocator)
	text := string(raw)
	testing.expect(
		t,
		!strings.contains(text, "s3cret-value") && !strings.contains(text, "vault:v2"),
	)
	for plain in ([]string{"API_KEY", "PLAIN", "--chrome", "cfg-work", "local-model"}) do testing.expect(t, strings.contains(text, plain))
	path := profile_secret_path(profile_env_secret_name("claude_w", "API_KEY"))
	value, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil && string(value) == "s3cret-value")
	for file in ([]string{path, g_profile_test_store_path, profile_secrets_dir()}) {
		info, e := os.stat(file, context.temp_allocator)
		testing.expect(t, e == nil)
		when ODIN_OS != .Windows {
			testing.expect(
				t,
				info.mode &
					os.Permissions {
							.Read_Group,
							.Read_Other,
							.Write_Group,
							.Write_Other,
							.Execute_Group,
							.Execute_Other,
						} ==
				{},
			)
		}
	}
	// No vault test seam at all: both lookup and upsert are independent of its state.
	got, lerr := profile_lookup("claude", "claude_w")
	testing.expect_value(t, lerr, Profile_Error.None)
	testing.expect_value(t, got.environment[0].value, "s3cret-value")
	profiles, _ := profile_list()
	testing.expect(
		t,
		profiles[0].environment[0].value == "" && profiles[0].environment[0].value_redacted,
	)
	upd := Provider_Profile {
		profile_id  = "claude_w",
		provider    = "claude",
		enabled     = true,
		environment = []Provider_Profile_Env {
			{name = "API_KEY", sensitive = true, value_redacted = true},
		},
	}
	testing.expect_value(t, profile_upsert(&upd, nil, 2000), Profile_Error.None)
	got, lerr = profile_lookup("claude", "claude_w")
	testing.expect_value(t, lerr, Profile_Error.None)
	testing.expect_value(t, got.environment[0].value, "s3cret-value")
	testing.expect_value(t, got.created_at, i64(1000))
	testing.expect_value(t, got.updated_at, i64(2000))
	_, mismatch := profile_lookup("codex", "claude_w")
	testing.expect_value(t, mismatch, Profile_Error.Provider_Mismatch)
	_, unknown := profile_lookup("claude", "gone")
	testing.expect_value(t, unknown, Profile_Error.Unknown)
	def, de := profile_lookup("claude", "")
	testing.expect(t, de == .None && def.profile_id == "claude")
	upd.enabled = false
	testing.expect_value(t, profile_upsert(&upd, nil, 3000), Profile_Error.None)
	_, disabled := profile_lookup("claude", "claude_w")
	testing.expect_value(t, disabled, Profile_Error.Disabled)
	testing.expect_value(t, profile_remove("claude"), Profile_Error.Default_Not_Removable)
	testing.expect_value(t, profile_remove("claude_w"), Profile_Error.None)
	testing.expect(t, !os.exists(path))
	testing.expect_value(t, profile_remove("claude_w"), Profile_Error.Not_Found)
}

@(test)
test_profile_secret_replace_clear_stale_and_non_sensitive :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile {
		profile_id = "ag_work",
		provider = "antigravity",
		enabled = true,
		config = Provider_Profile_Config {
			auth_method = "gemini-api-key",
			api_key = "config-secret",
		},
		environment = []Provider_Profile_Env {
			{name = "TOKEN", value = "old-secret", sensitive = true},
		},
	}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	env_path := profile_secret_path(profile_env_secret_name(p.profile_id, "TOKEN"))
	config_path := profile_secret_path(
		profile_config_secret_name(p.profile_id, "antigravity", "api_key"),
	)
	list, _ := profile_list()
	view := profile_view(&list[0])
	testing.expect(t, view.config.api_key == "" && view.config.api_key_redacted)
	p.config.api_key = ""
	p.config.api_key_redacted = true // keep config while replacing env
	p.environment[0].value = "new-secret"
	testing.expect_value(t, profile_upsert(&p, nil, 2), Profile_Error.None)
	got, e := profile_lookup("antigravity", p.profile_id)
	testing.expect(
		t,
		e == .None &&
		got.config.api_key == "config-secret" &&
		got.environment[0].value == "new-secret",
	)
	view = profile_view(&got)
	bytes, _ := json.marshal(view, allocator = context.temp_allocator)
	testing.expect(
		t,
		!strings.contains(string(bytes), "config-secret") &&
		!strings.contains(string(bytes), "new-secret"),
	)
	p.config.api_key_redacted = false // explicit empty clears
	p.environment[0].sensitive = false
	p.environment[0].value = "plain"
	testing.expect_value(t, profile_upsert(&p, nil, 3), Profile_Error.None)
	testing.expect(t, !os.exists(config_path) && !os.exists(env_path))
	p.config.api_key = "second"
	p.environment[0].sensitive = true
	p.environment[0].value = "second"
	testing.expect_value(t, profile_upsert(&p, nil, 4), Profile_Error.None)
	p.environment = nil // stale env cleanup
	p.config.api_key = ""
	testing.expect_value(t, profile_upsert(&p, nil, 5), Profile_Error.None)
	testing.expect(t, !os.exists(config_path) && !os.exists(env_path))
	// Keep with no pre-existing secret stays redacted and materializes empty.
	p.config.api_key_redacted = true
	testing.expect_value(t, profile_upsert(&p, nil, 6), Profile_Error.None)
	got, e = profile_lookup("antigravity", p.profile_id)
	testing.expect(t, e == .None && got.config.api_key == "")
}

@(test)
test_profile_secret_transaction_rolls_back :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile {
		profile_id  = "claude_w",
		provider    = "claude",
		enabled     = true,
		environment = []Provider_Profile_Env{{name = "TOKEN", value = "before", sensitive = true}},
	}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	path := profile_secret_path(profile_env_secret_name(p.profile_id, "TOKEN"))
	// A directory at the settings temporary filename forces the final write to
	// fail after secret writes. The prior settings and secret must survive.
	tmp := strings.concatenate({g_profile_test_store_path, ".tmp"}, context.temp_allocator)
	testing.expect(t, os.make_directory(tmp, {.Read_User, .Write_User, .Execute_User}) == nil)
	child := strings.concatenate({tmp, "/block"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(child, []byte{'x'}) == nil)
	p.environment = []Provider_Profile_Env {
		{name = "TOKEN", value = "after", sensitive = true},
		{name = "NEW", value = "new", sensitive = true},
	}
	testing.expect_value(t, profile_upsert(&p, nil, 2), Profile_Error.Store_Unavailable)
	raw, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil && string(raw) == "before")
	testing.expect(
		t,
		!os.exists(profile_secret_path(profile_env_secret_name(p.profile_id, "NEW"))),
	)
	got, e := profile_lookup("claude", p.profile_id)
	testing.expect(t, e == .None && len(got.environment) == 1 && got.updated_at == 1)
	// A later secret-file write can also fail after the first one succeeded.
	_ = os.remove_all(tmp)
	new_path := profile_secret_path(profile_env_secret_name(p.profile_id, "NEW"))
	new_tmp := strings.concatenate({new_path, ".tmp"}, context.temp_allocator)
	testing.expect(t, os.make_directory(new_tmp, {.Read_User, .Write_User, .Execute_User}) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			strings.concatenate({new_tmp, "/block"}, context.temp_allocator),
			[]byte{'x'},
		) ==
		nil,
	)
	testing.expect_value(t, profile_upsert(&p, nil, 3), Profile_Error.Store_Unavailable)
	raw, err = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil && string(raw) == "before")
	testing.expect(t, !os.exists(new_path))

}

@(test)
test_profile_reset_purge_and_secret_namespace :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile {
		profile_id  = "claude",
		provider    = "claude",
		enabled     = true,
		environment = []Provider_Profile_Env{{name = "TOKEN", value = "secret", sensitive = true}},
	}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	path := profile_secret_path(profile_env_secret_name("claude", "TOKEN"))
	testing.expect_value(t, profile_reset("claude"), Profile_Error.None)
	testing.expect(t, !os.exists(path))
	p.profile_id = "claude_other"
	testing.expect_value(t, profile_upsert(&p, nil, 2), Profile_Error.None)
	other := profile_secret_path(profile_env_secret_name(p.profile_id, "TOKEN"))
	testing.expect(t, os.exists(other) && !os.exists(path))
	testing.expect(t, profile_env_secret_name("a_b", "C") != profile_env_secret_name("a", "b_C"))
	testing.expect(t, profile_purge())
	testing.expect(t, !os.exists(g_profile_test_store_path) && !os.exists(profile_secrets_dir()))
}

@(test)
test_profile_dirs_leaf_only_and_report_metadata_only :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	deep := Provider_Profile {
		profile_id = "codex_d",
		provider = "codex",
		enabled = true,
		config = Provider_Profile_Config {
			home_path = strings.concatenate({dir, "/missing/leaf"}, context.temp_allocator),
		},
	}
	testing.expect_value(t, profile_upsert(&deep, nil, 1), Profile_Error.Path_Invalid)
	p := Provider_Profile {
		profile_id = "codex_x",
		provider = "codex",
		enabled = true,
		accent = "#112233",
		config = Provider_Profile_Config {
			home_path = strings.concatenate({dir, "/codex-home"}, context.temp_allocator),
			launch_args = "--a --b",
			custom_models = []string{"private-model"},
		},
		environment = []Provider_Profile_Env {
			{name = "SECRET_NAME", value = "secret-val", sensitive = true},
		},
	}
	testing.expect_value(t, profile_upsert(&p, nil, 5), Profile_Error.None)
	report := profile_report_json(context.temp_allocator)
	for leak in ([]string{"secret-val", "SECRET_NAME", "codex-home", "--a", "private-model"}) do testing.expect(t, !strings.contains(report, leak))
	wire: Provider_Profiles_Report_Wire
	testing.expect(
		t,
		json.unmarshal_string(report, &wire, json.Specification.JSON, context.temp_allocator) ==
		nil,
	)
	testing.expect_value(t, len(wire.profiles), 1)
	if len(wire.profiles) == 1 {
		e := wire.profiles[0]
		testing.expect(t, e.has_home_path && !e.has_config_dir && !e.has_binary)
		testing.expect_value(t, e.env_count, 1)
		testing.expect_value(t, e.args_count, 2)
		testing.expect_value(t, e.custom_models_count, 1)
	}
}

// ── Sealed ops (amendment 5) ────────────────────────────────────────────────

PROFILE_OP_KEY1 :: "1111111111111111111111111111111111111111111111111111111111111111"
@(private = "file")
PROFILE_OP_KEY2 :: "2222222222222222222222222222222222222222222222222222222222222222"

@(private = "file")
profile_op_seal :: proc(kr: ^vault.Vault_Keyring, op: Provider_Profile_Op_Wire) -> string {
	data, _ := json.marshal(op, allocator = context.temp_allocator)
	tok, _ := vault.seal_string(string(data), kr, context.temp_allocator)
	return tok
}

@(test)
test_profile_op_open_checks :: proc(t: ^testing.T) {
	now := profile_now_ms()
	kr := test_keyring_two_epochs(PROFILE_OP_KEY1, PROFILE_OP_KEY2)
	defer vault.keyring_wipe(&kr)
	old := test_keyring_from_hex(PROFILE_OP_KEY1, 1)
	defer vault.keyring_wipe(&old)
	base := Provider_Profile_Op_Wire {
		op         = "get",
		profile_id = "claude",
		bridge_id  = "brg_a",
		boot_id    = "boot1",
		ts         = now,
	}

	ok_op := base
	ok_op.nonce = "nonce-ok-0000000001"
	op, err := profile_op_open(profile_op_seal(&kr, ok_op), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, err, "")
	testing.expect_value(t, op.op, "get")

	// Replayed nonce.
	_, rerr := profile_op_open(profile_op_seal(&kr, ok_op), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, rerr, "profile_replay")

	// Older epoch: a revoked device only holds pre-rotation keys.
	stale := base
	stale.nonce = "nonce-stale-00000001"
	_, serr := profile_op_open(profile_op_seal(&old, stale), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, serr, "profile_stale_epoch")

	wrong := base
	wrong.nonce = "nonce-wrong-00000001"
	wrong.bridge_id = "brg_b"
	_, werr := profile_op_open(profile_op_seal(&kr, wrong), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, werr, "profile_wrong_bridge")

	boot := base
	boot.nonce = "nonce-boot-000000001"
	boot.boot_id = "boot0"
	_, berr := profile_op_open(profile_op_seal(&kr, boot), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, berr, "profile_stale_boot")

	expired := base
	expired.nonce = "nonce-expired-000001"
	expired.ts = now - 10 * 60_000
	_, eerr := profile_op_open(profile_op_seal(&kr, expired), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, eerr, "profile_expired")

	_, perr := profile_op_open("not a token", &kr, "brg_a", "boot1", now)
	testing.expect_value(t, perr, "profile_bad_seal")
	_, lerr := profile_op_open(profile_op_seal(&kr, ok_op), nil, "brg_a", "boot1", now)
	testing.expect_value(t, lerr, "profile_locked")
}

@(test)
test_profile_op_apply_upsert_get_redacts :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	up := Provider_Profile_Op_Wire {
		op = "upsert",
		profile_id = "claude_w",
		nonce = "n1",
		body = Provider_Profile_Body_Wire {
			provider = "claude",
			enabled = true,
			accent = "#00aa00",
			environment = []Provider_Profile_Env_Wire {
				{name = "TOKEN", value = "tok-secret", sensitive = true},
				{name = "MODE", value = "fast"},
			},
			config = Provider_Profile_Config{launch_args = "--verbose"},
		},
	}
	testing.expect_value(t, profile_op_apply(&up, 10).error, "")
	get := Provider_Profile_Op_Wire {
		op         = "get",
		profile_id = "claude_w",
		nonce      = "n2",
	}
	out := profile_op_apply(&get, 11)
	testing.expect_value(t, out.error, "")
	testing.expect(t, !strings.contains(out.response, "tok-secret"))
	testing.expect(
		t,
		strings.contains(out.response, `"value_redacted":true`) &&
		strings.contains(out.response, "fast") &&
		strings.contains(out.response, "--verbose"),
	)
	// Keep the redacted secret on the next edit.
	up2 := up
	up2.nonce = "n3"
	up2.body.environment = []Provider_Profile_Env_Wire {
		{name = "TOKEN", value = "", sensitive = true, keep = true},
	}
	testing.expect_value(t, profile_op_apply(&up2, 12).error, "")
	p, _ := profile_lookup("claude", "claude_w")
	testing.expect(t, len(p.environment) == 1 && p.environment[0].value == "tok-secret")
	// Unedited default profile is readable; unknown ids are not.
	def := Provider_Profile_Op_Wire {
		op         = "get",
		profile_id = "codex",
		nonce      = "n4",
	}
	testing.expect_value(t, profile_op_apply(&def, 13).error, "")
	missing := Provider_Profile_Op_Wire {
		op         = "get",
		profile_id = "codex_x",
		nonce      = "n5",
	}
	testing.expect_value(t, profile_op_apply(&missing, 14).error, "profile_not_found")
	bad := Provider_Profile_Op_Wire {
		op         = "drop",
		profile_id = "claude_w",
	}
	testing.expect_value(t, profile_op_apply(&bad, 15).error, "profile_bad_op")
	// Reset is for default profiles only; remove takes the provider from the record.
	rst := Provider_Profile_Op_Wire {
		op         = "reset",
		profile_id = "claude_w",
	}
	testing.expect_value(t, profile_op_apply(&rst, 16).error, "profile_invalid_id")
	rm_default := Provider_Profile_Op_Wire {
		op         = "remove",
		profile_id = "codex",
	}
	testing.expect_value(
		t,
		profile_op_apply(&rm_default, 17).error,
		"profile_default_not_removable",
	)
	rm := Provider_Profile_Op_Wire {
		op         = "remove",
		profile_id = "claude_w",
	}
	testing.expect_value(t, profile_op_apply(&rm, 18).error, "")
}

@(test)
test_profile_launch_argv_and_env :: proc(t: ^testing.T) {
	prof := Bridge_Provider_Profile {
		name            = "claude",
		command         = []string{"/bin/claude"},
		base_args       = []string{"--b"},
		yolo_flags      = []string{"--y"},
		model_flag      = "--model",
		extra_args      = []string{"--chrome", "--x=1"},
		prompt_delivery = "none",
	}
	argv := bridge_runtime_agent_argv_for_profile(prof, "opus", "tok", "inst")
	defer delete(argv)
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expect_value(t, joined, "/bin/claude --b --y --model opus --chrome --x=1")
}

@(test)
test_profile_reset_keeps_enabled_and_clears_overrides :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	off := Provider_Profile_Op_Wire {
		op = "upsert",
		profile_id = "claude",
		body = Provider_Profile_Body_Wire {
			provider = "claude",
			enabled = false,
			accent = "#123456",
			config = Provider_Profile_Config{launch_args = "--x"},
		},
	}
	testing.expect_value(t, profile_op_apply(&off, 1).error, "")
	rst := Provider_Profile_Op_Wire {
		op         = "reset",
		profile_id = "claude",
	}
	testing.expect_value(t, profile_op_apply(&rst, 2).error, "")
	_, err := profile_lookup("claude", "")
	testing.expect_value(t, err, Profile_Error.Disabled)
	profiles, _ := profile_list()
	testing.expect_value(t, len(profiles), 1)
	if len(profiles) == 1 do testing.expect(t, profiles[0].accent == "" && profiles[0].config.launch_args == "")
	// An enabled default with overrides resets to the implicit default.
	on := Provider_Profile_Op_Wire {
		op = "upsert",
		profile_id = "codex",
		body = Provider_Profile_Body_Wire {
			provider = "codex",
			enabled = true,
			config = Provider_Profile_Config{launch_args = "--y"},
		},
	}
	testing.expect_value(t, profile_op_apply(&on, 3).error, "")
	rst2 := Provider_Profile_Op_Wire {
		op         = "reset",
		profile_id = "codex",
	}
	testing.expect_value(t, profile_op_apply(&rst2, 4).error, "")
	def, derr := profile_lookup("codex", "codex")
	testing.expect_value(t, derr, Profile_Error.None)
	testing.expect_value(t, len(profile_tokenize_args(def.config.launch_args)), 0)
}

@(test)
test_profile_paths_normalized_and_empty_args_dropped :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile {
		profile_id = "claude_n",
		provider = "claude",
		enabled = true,
		config = Provider_Profile_Config {
			config_dir = strings.concatenate({dir, "/./a/../cfg-n/"}, context.temp_allocator),
			launch_args = "",
		},
	}
	p.config.launch_args = "\"\" --keep ''"
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	got, _ := profile_lookup("claude", "claude_n")
	testing.expect_value(
		t,
		got.config.config_dir,
		strings.concatenate({dir, "/cfg-n"}, context.temp_allocator),
	)
	testing.expect_value(t, len(profile_tokenize_args(got.config.launch_args)), 1)
	tilde := profile_normalize_path("~/x/../y")
	testing.expect(
		t,
		filepath_is_abs_test(tilde) &&
		strings.has_suffix(tilde, "/y") &&
		!strings.contains(tilde, "~"),
	)
	testing.expect_value(t, profile_normalize_path("rel/p"), "rel/p")
}

@(private = "file")
filepath_is_abs_test :: proc(p: string) -> bool {
	return len(p) > 0 && p[0] == '/'
}

@(test)
test_profile_slug_clash_is_reported :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	// "newprov" is not in the catalog yet: a claude profile may use the id.
	p := Provider_Profile {
		profile_id = "newprov",
		provider   = "claude",
		enabled    = true,
	}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	// A later catalog adds the slug.
	prev := g_profile_test_catalog
	clash_catalog := [?]string{"claude", "codex", "pi", "copilot", "newprov"}
	g_profile_test_catalog = clash_catalog[:]
	defer g_profile_test_catalog = prev
	_, err := profile_lookup("newprov", "")
	testing.expect_value(t, err, Profile_Error.Slug_Clash)
	report := profile_report_json(context.temp_allocator)
	testing.expect(t, strings.contains(report, `"state":"slug_clash"`))
	// The custom profile itself keeps working.
	_, cerr := profile_lookup("claude", "newprov")
	testing.expect_value(t, cerr, Profile_Error.None)
}

// Golden vector shared with the UI encoder (P3): a fixed key, vault id, epoch and
// nonce over the canonical envelope bytes give this exact token.
PROFILE_GOLDEN_PLAIN :: `{"op":"upsert","profile_id":"claude_k3fq","body":{"provider":"claude","label_enc":"","accent":"#a1b2c3","enabled":true,"environment":[{"name":"ANTHROPIC_API_KEY","value":"sk-golden","sensitive":true,"value_redacted":false,"keep":false}],"config":{"binary_path":"","config_dir":"/home/dev/.claude-work","home_path":"","shadow_home_path":"","launch_args":"--chrome","custom_models":["work-model"],"auth_method":"","api_key":"","api_key_redacted":false,"gcp_project":"","gcp_location":""}},"bridge_id":"brg_golden","boot_id":"boot_golden","ts":1793350000000,"nonce":"golden-nonce-000001"}`
PROFILE_GOLDEN_NONCE :: "000102030405060708090a0b"

@(test)
test_profile_op_golden_vector :: proc(t: ^testing.T) {
	kr := test_keyring_from_hex(PROFILE_OP_KEY1, 1)
	defer vault.keyring_wipe(&kr)
	key, _ := vault.keyring_key_for_epoch(&kr, 1)
	nonce: [vault.NONCE_BYTES]byte
	_ = vault.hex_decode_into(nonce[:], PROFILE_GOLDEN_NONCE)
	tok, ok := vault.seal_with_nonce(
		transmute([]byte)string(PROFILE_GOLDEN_PLAIN),
		key,
		kr.vault_id,
		1,
		nonce[:],
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect_value(t, tok, PROFILE_GOLDEN_TOKEN)
	op, err := profile_op_open(
		PROFILE_GOLDEN_TOKEN,
		&kr,
		"brg_golden",
		"boot_golden",
		1793350000000,
	)
	testing.expect_value(t, err, "")
	testing.expect_value(t, op.op, "upsert")
	testing.expect_value(t, op.profile_id, "claude_k3fq")
	testing.expect_value(t, op.body.provider, "claude")
	testing.expect_value(t, op.body.config.config_dir, "/home/dev/.claude-work")
	testing.expect(
		t,
		len(op.body.environment) == 1 &&
		op.body.environment[0].name == "ANTHROPIC_API_KEY" &&
		op.body.environment[0].sensitive,
	)
	testing.expect(t, op.body.config.launch_args == "--chrome")
	testing.expect_value(t, op.nonce, "golden-nonce-000001")
}

PROFILE_GOLDEN_TOKEN :: "vault:v2:c8f193e678e762f9:e1:AAECAwQFBgcICQoLgk1tS2fB7s7XqvMlNCD8hmjB2WNZmReBZMu27bCN2wS5028OfBk3cMCEnUXfIw9PAtYs6yc2EKZUozSZ6yd3gEWqWgTL6XiCF49+9U1uUjeiRQnwZp0F0JL/UYahpN6Y0m22UlMtJ0EN/Ghjz0Y0kNrFSUyPAnZeyvaiVdkgxt87D1Yh5RfckkfaqwRvD/dqEN0wByqHvsOUFVZmi69T9YT6dMTwdSYWvjUBvTeTEkAj7Nsea6fUNS6qs7v184USuARlHw9vdy6apVKmo/jZe1iHfONyLu2FK1SMZlaiEi9IEtbh8EU2tkOyWMZ/DWjPJBg2y7FaDfRTgaoFzP6/0ECPnjout6KEVyRerL8O+XrWDqR1aE2LIDUvCqUXnB2PSfHqJc5dZqPlnUhw3RaVIbeiSOjEgDTcEiTuDV16XG1QjkfowOKaa4KWum61i/Olz1ADoS985PJUGVLCIUNjIYwYhB5qgrY1/sWIi/EkQ81ImD0LWVaRGwu6mxdCspCoQAkTtboe7UVsC4Y1B+EeLGdOP8bdTWnBHe+sfvwV3Vm55WX2yYJSvco8jmkwf6EhDq19UIp81XfWniTW8yYuvP3cJW/LFZFYPSmlp8IiEIOo+zyGlbr/fodGBHrSXPNPuxWPXssCNxCC3i2mv0lOWyxTHziPApGUH8yGA/JHXD4fFYeBr4r7sESs1xheXqnMd4jSbBhCGWx5fm3fCI2HZVFPi2FlrsiCeb8SqtVeEeSFjIrXQuqMHN2YGxed08yZcPMBC9/DCuC4XMCQKsA7lo1SBbws7zsLxA=="

// Exercise the actual Spawn assembler with an explicit binary and a model that
// exists only on this profile; never start a provider process.
@(test)
test_profile_spawn_binary_custom_model_args_and_env :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	snap := Bridge_Provider_Catalog_Snapshot {
		providers = []Bridge_Catalog_Provider {
			{
				provider = "claude",
				state = "active",
				binary = "claude",
				base_args = []string{"--base"},
				model_flag = "--model",
				prompt_delivery = "arg",
				prompt_args = []string{"--prompt"},
				starter_prompt = "hello",
				models = []Bridge_Catalog_Model{{model_id = "seed", state = "active"}},
			},
		},
	}
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	old_snap, old_loaded := bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded
	bridge_provider_catalog_snapshot = &snap
	bridge_provider_catalog_loaded = true
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	defer {
		sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
		bridge_provider_catalog_snapshot = old_snap
		bridge_provider_catalog_loaded = old_loaded
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	}
	pp := Provider_Profile {
		profile_id = "claude_work",
		provider = "claude",
		enabled = true,
		config = Provider_Profile_Config {
			binary_path = "/explicit/claude",
			config_dir = "/config",
			launch_args = `--name "work profile" '$HOME'`,
			custom_models = []string{"custom"},
		},
		environment = []Provider_Profile_Env {
			{name = "CLAUDE_CONFIG_DIR", value = "/env-dir"},
			{name = "TOKEN", value = "local-secret"},
		},
	}
	req, ok := bridge_pty_host_build_spawn(
		"profile_spawn_test",
		"/run/test",
		"claude",
		"custom",
		"agent-token",
		[]string{"HEIMDALL_AGENT_TOKEN=forced-token"},
		pp = &pp,
	)
	if !testing.expect(t, ok) do return
	defer bridge_pty_host_spawn_request_delete(req)
	expected := []string {
		"/explicit/claude",
		"--base",
		"--model",
		"custom",
		"--name",
		"work profile",
		"$HOME",
		"--prompt",
		"hello",
	}
	testing.expect_value(t, len(req.argv), len(expected))
	for a, i in req.argv do if i < len(expected) - 1 do testing.expect_value(t, a, expected[i])
	testing.expect(
		t,
		strings.has_prefix(req.argv[len(req.argv) - 1], "hello") &&
		strings.contains(req.argv[len(req.argv) - 1], "Heimdall runtime:"),
	)
	dir, token, launch_token := "", "", ""
	for kv in req.env {
		if kv[0] == "CLAUDE_CONFIG_DIR" do dir = kv[1]
		if kv[0] == "TOKEN" do token = kv[1]
		if kv[0] == "HEIMDALL_AGENT_TOKEN" do launch_token = kv[1]
		testing.expect(t, kv[0] != "HOME")
	}
	testing.expect_value(t, dir, "/config")
	testing.expect_value(t, token, "local-secret")
	testing.expect_value(t, launch_token, "forced-token")
}

@(test)
test_profile_op_relay_route_binding :: proc(t:^testing.T) {
 op:=Provider_Profile_Op_Wire{op="remove",profile_id="claude_one"}
 testing.expect(t,profile_op_route_matches(&op,"remove","claude_one"))
 testing.expect(t,!profile_op_route_matches(&op,"get","claude_one"),"sealed remove cannot use the get route")
 testing.expect(t,!profile_op_route_matches(&op,"upsert","claude_one"),"sealed remove cannot use PUT")
 testing.expect(t,!profile_op_route_matches(&op,"remove","claude_two"),"sealed profile cannot substitute a different route ID")
 testing.expect(t,!profile_op_route_matches(&op,"",""),"route binding is required")
}
