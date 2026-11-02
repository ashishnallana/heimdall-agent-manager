#+private file
package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider "odin_test:hub/service/provider"

@(test)
test_profiles_migration_preserves_default_provider_meaning :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, err := run_migrations(&conn, stop_before = "169_provider_profiles.sql")
	if !testing.expect(t, ok, err.message) do return
	testing.expect(t, upgrade_task_chain_fleets_schema(&conn))
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('profiles-b','owner','',''); INSERT INTO bridge_provider_status(bridge_id,provider,binary_path,version_text,state,checked_at) VALUES('profiles-b','claude','/legacy/bin','legacy-v','present','checked'); INSERT INTO bridge_provider_settings VALUES('profiles-b','claude',1,'updated'); INSERT INTO bridge_provider_models(bridge_id,provider,has_snapshot,models_json,models_state) VALUES('profiles-b','claude',1,'[]','success'); INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,provider,model,runtime_status,created_at,updated_at) VALUES('profiles-inst','owner','agent','profiles-b','claude','model','stopped','','');",
		),
	)
	ok, err = run_migrations(&conn)
	if !testing.expect(t, ok, err.message) do return
	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl, &conn)
	statuses, _ := repo.list_status(repo.ctx, "profiles-b")
	testing.expect_value(t, len(statuses), 1)
	if len(statuses) ==
	   1 {testing.expect_value(t, statuses[0].profile_id, "claude"); testing.expect_value(t, statuses[0].binary_path, "/legacy/bin"); testing.expect_value(t, statuses[0].state, "present")}
	settings, _ := repo.list_settings(repo.ctx, "profiles-b")
	testing.expect_value(t, len(settings), 1)
	if len(settings) ==
	   1 {testing.expect_value(t, settings[0].profile_id, "claude"); testing.expect(t, settings[0].enabled)}
	models, _ := repo.list_models(repo.ctx, "profiles-b")
	testing.expect_value(t, len(models), 1)
	if len(models) ==
	   1 {testing.expect_value(t, models[0].profile_id, "claude"); testing.expect(t, models[0].has_snapshot); testing.expect_value(t, models[0].models_json, "[]")}
	ai: Agent_Repo_SQLite
	ar := new_agent_repository(&ai, &conn)
	inst, found, _ := iface.agent_get_instance(&ar, "profiles-inst")
	testing.expect(t, found); testing.expect_value(t, inst.provider_profile, "claude")
	ok, err = run_migrations(&conn)
	testing.expect(t, ok, err.message)
	testing.expect(
		t,
		exec(&conn, "DELETE FROM schema_migrations WHERE version='169_provider_profiles.sql';"),
	)
	ok, err = run_migrations(&conn)
	testing.expect(t, ok, err.message)
	testing.expect(
		t,
		migration_applied(&conn, "169_provider_profiles.sql"),
		"schema/ledger crash recovery restores the ledger",
	)
	// Exact allowlist: no config object, executable/path, argument or environment.
	columns := profile_test_text(
		&conn,
		"SELECT group_concat(name,',') FROM pragma_table_info('bridge_provider_profiles');",
	)
	testing.expect_value(
		t,
		columns,
		"bridge_id,profile_id,provider,label_enc,accent,enabled,has_config_dir,has_home_path,has_shadow_home_path,has_binary,env_count,args_count,custom_models_count,state,created_at,updated_at",
	)
}

@(test)
test_profiles_reconcile_missing_references_scope_and_reset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('profiles-a','owner','',''),('profiles-b','owner','','');",
		),
	)
	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl, &conn)
	svc := provider.new_provider_service(&repo)
	records := []domain.Bridge_Provider_Profile {
		{
			profile_id = "claude_one",
			provider = "claude",
			label_enc = "vault:v2:test:e1:label",
			enabled = true,
			state = "ok",
			env_count = 2,
		},
		{profile_id = "claude_two", provider = "claude", enabled = false, state = "ok"},
		{
			profile_id = "claude",
			provider = "claude",
			enabled = false,
			state = "ok",
			has_config_dir = true,
		},
	}
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profiles-a", records).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profiles-b", records[:1]).code,
		domain.Error_Code.None,
	)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,provider,provider_profile,model,runtime_status,created_at,updated_at) VALUES('profile-live','owner','agent','profiles-a','claude','claude_one','model','running','','');",
		),
	)
	refs, rerr := repo.profile_references(repo.ctx, "profiles-a", "claude_one")
	testing.expect_value(t, rerr.code, domain.Error_Code.None)
	testing.expect(t, strings.contains(refs, "profile-live"))
	_, _ = repo.upsert_status(
		repo.ctx,
		{
			bridge_id = "profiles-a",
			profile_id = "claude_one",
			provider = "claude",
			state = "present",
		},
	)
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profiles-a", nil).code,
		domain.Error_Code.None,
	)
	profiles, _ := repo.list_profiles(repo.ctx, "profiles-a")
	missing, reset, removed := false, false, true
	for p in profiles {
		if p.profile_id == "claude_one" {missing = p.state == "missing" && !p.enabled}
		if p.profile_id ==
		   "claude" {reset = p.state == "ok" && p.enabled && !p.has_config_dir && p.label_enc == ""}
		if p.profile_id == "claude_two" do removed = false
	}
	testing.expect(t, missing, "live reference retains a missing row")
	testing.expect(t, reset, "default reset remains implicit and usable")
	testing.expect(t, removed, "unreferenced absent row removed")
	other, _ := repo.list_profiles(repo.ctx, "profiles-b")
	found := false
	for p in other do if p.profile_id == "claude_one" do found = true
	testing.expect(t, found, "other bridge unaffected")
	statuses, _ := repo.list_status(repo.ctx, "profiles-a")
	testing.expect_value(t, len(statuses), 0)
	testing.expect(
		t,
		exec(
			&conn,
			"UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='profile-live';",
		),
	)
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profiles-a", nil).code,
		domain.Error_Code.None,
	)
	profiles, _ = repo.list_profiles(repo.ctx, "profiles-a")
	for p in profiles do testing.expect(t, p.profile_id != "claude_one")
}

@(test)
test_profiles_reconcile_validation_is_atomic_and_driver_bound :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('profile-validation','owner','','');",
		),
	)
	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl, &conn)
	svc := provider.new_provider_service(&repo)
	valid := domain.Bridge_Provider_Profile {
		profile_id = "claude_one",
		provider   = "claude",
		enabled    = true,
		state      = "ok",
	}
	invalid := valid; invalid.profile_id = "codex"
	testing.expect(
		t,
		provider.apply_profiles_report(&svc, "profile-validation", []domain.Bridge_Provider_Profile{valid, invalid}).code !=
		.None,
		"new profile cannot occupy another driver's slug",
	)
	profiles, _ := repo.list_profiles(repo.ctx, "profile-validation")
	testing.expect_value(t, len(profiles), 0)
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profile-validation", []domain.Bridge_Provider_Profile{valid}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		provider.validate_profile(&repo, "profile-validation", "claude", "claude_one").code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		provider.validate_profile(&repo, "profile-validation", "codex", "claude_one").cause,
		"profile_unknown",
	)
	valid.enabled = false
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profile-validation", []domain.Bridge_Provider_Profile{valid}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		provider.validate_profile(&repo, "profile-validation", "claude", "claude_one").cause,
		"profile_disabled",
	)
	invalid.state = "slug_clash"
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profile-validation", []domain.Bridge_Provider_Profile{valid, invalid}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		provider.validate_profile(&repo, "profile-validation", "claude", "codex").code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		provider.validate_profile(&repo, "profile-validation", "codex", "codex").cause,
		"profile_slug_clash",
	)

}

@(test)
test_profiles_model_status_settings_isolate_accounts_and_custom_models :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('profile-models','owner','','');",
		),
	)
	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl, &conn)
	svc := provider.new_provider_service(&repo)
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profile-models", []domain.Bridge_Provider_Profile{{profile_id = "codex_one", provider = "codex", enabled = true, state = "ok"}, {profile_id = "codex_two", provider = "codex", enabled = true, state = "ok"}}).code,
		domain.Error_Code.None,
	)
	for id in ([]string{"codex_one", "codex_two"}) {
		testing.expect_value(
			t,
			provider.apply_discovery_report(&svc, "profile-models", []domain.Bridge_Provider_Status{{bridge_id = "profile-models", profile_id = id, provider = "codex", binary_path = "/private/bin", state = "present"}}).code,
			domain.Error_Code.None,
		)
	}
	first := provider.Model_Discovery_Item {
		profile_id          = "codex_one",
		provider            = "codex",
		binary_path         = "/private/bin",
		models_state        = "unsupported",
		models_attempted_at = "today",
		custom_models       = []string{"private-model-one"},
	}
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "profile-models", []string{"codex"}, []provider.Model_Discovery_Item{first}, "codex_one").code,
		domain.Error_Code.None,
	)
	err := provider.validate_launchable(
		&svc,
		"profile-models",
		"codex",
		"private-model-one",
		"codex_one",
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	err = provider.validate_launchable(
		&svc,
		"profile-models",
		"codex",
		"private-model-one",
		"codex_two",
	)
	testing.expect(t, err.code != .None, "another account cannot borrow custom models")
	first.has_snapshot =
		true; first.models_state = "success"; first.models_source = "codex_app_server"; first.models_checked_at = "today"
	first.models = []provider.Discovered_Model {
		{model_id = "observed-one", label = "Observed"},
		{model_id = "private-model-one", label = "Custom"},
	}
	first.observed_models_json = "[{\"model_id\":\"observed-one\",\"label\":\"Observed\"}]"
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "profile-models", []string{"codex"}, []provider.Model_Discovery_Item{first}, "codex_one").code,
		domain.Error_Code.None,
	)
	first.custom_models =
		nil; first.has_snapshot = false; first.models = nil; first.observed_models_json = ""; first.models_state = "authentication_required"
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "profile-models", []string{"codex"}, []provider.Model_Discovery_Item{first}, "codex_one").code,
		domain.Error_Code.None,
	)
	err = provider.validate_launchable(
		&svc,
		"profile-models",
		"codex",
		"observed-one",
		"codex_one",
	)
	testing.expect(t, err.code == .None, "failed probe retains last good observed model")
	err = provider.validate_launchable(
		&svc,
		"profile-models",
		"codex",
		"private-model-one",
		"codex_one",
	)
	testing.expect(
		t,
		err.code != .None,
		"clearing custom models cannot leave a ghost in observed provenance",
	)
	statuses, _ := repo.list_status(repo.ctx, "profile-models")
	testing.expect_value(t, len(statuses), 2)
	for s in statuses do testing.expect_value(t, s.binary_path, "")
	models, _ := repo.list_models(repo.ctx, "profile-models")
	for m in models do testing.expect_value(t, m.binary_path, "")
	_, _ = repo.upsert_setting(
		repo.ctx,
		{
			bridge_id = "profile-models",
			provider = "codex",
			profile_id = "codex_one",
			enabled = false,
		},
	)
	err = provider.validate_launchable(
		&svc,
		"profile-models",
		"codex",
		"observed-one",
		"codex_one",
	)
	testing.expect(t, err.code != .None, "profile setting disables only that identity")
}

profile_test_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

@(test)
test_profiles_instance_fleet_lease_roundtrip_and_references :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('profile-runtime','owner','','');",
		),
	)
	ai: Agent_Repo_SQLite
	ar := new_agent_repository(&ai, &conn)
	initial := domain.Agent_Instance {
		agent_instance_id = "profile-instance",
		owner_user_id     = "owner",
		agent_id          = "profile-agent",
		bridge_id         = "profile-runtime",
		provider          = "claude",
		model             = "model",
		runtime_status    = "stopped",
	}
	saved, stored, err := iface.agent_save_instance(&ar, initial)
	testing.expect(t, stored, err.message)
	current, found, _ := iface.agent_get_instance(&ar, initial.agent_instance_id)
	testing.expect(t, found)
	testing.expect_value(t, current.provider_profile, "claude")
	current.provider_profile = "claude_one"
	saved, stored, err = iface.agent_save_instance(&ar, current)
	testing.expect(
		t,
		stored,
		err.message,
	); testing.expect_value(t, saved.configuration_revision, 1)
	reloaded, _, _ := iface.agent_get_instance(&ar, initial.agent_instance_id)
	testing.expect_value(t, reloaded.provider_profile, "claude_one")
	_, stored, _ = iface.agent_save_instance(&ar, initial)
	testing.expect(t, !stored, "stale heartbeat cannot restore old account selection")
	ti: Taskchain_Repo_SQLite
	tr := new_taskchain_repository(&ti, &conn)
	_, stored, err = iface.taskchain_save_chain(
		&tr,
		domain.Task_Chain {
			chain_id = "profile-chain",
			owner_user_id = "owner",
			title = "Profiles",
			publish_state = .Published,
			status = .Active,
			kind = domain.CHAIN_KIND_MIXED_WORK,
		},
	)
	testing.expect(t, stored, err.message)
	_, err = iface.taskchain_upsert_fleet(
		&tr,
		domain.Task_Chain_Fleet {
			task_chain_id = "profile-chain",
			agent_id = "profile-agent",
			capacity = 1,
			provider = "claude",
			provider_profile = "claude_one",
			model = "model",
			bridge_id = "profile-runtime",
			bridge_models_json = "{\"profile-runtime\":{\"provider\":\"codex\",\"provider_profile\":\"codex_two\",\"model\":\"model\"}}",
		},
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	fleets, fe := iface.taskchain_list_fleets_by_chain(&tr, "profile-chain", "owner")
	testing.expect_value(
		t,
		fe.code,
		domain.Error_Code.None,
	); testing.expect_value(t, len(fleets), 1)
	if len(fleets) == 1 do testing.expect_value(t, fleets[0].provider_profile, "claude_one")
	pi: Provider_Repo_SQLite
	pr := new_provider_repository(&pi, &conn)
	refs, rerr := pr.profile_references(pr.ctx, "profile-runtime", "codex_two")
	testing.expect_value(
		t,
		rerr.code,
		domain.Error_Code.None,
	); testing.expect(t, strings.contains(refs, "profile-chain:profile-agent"), "per-bridge fleet override retains its own profile")
	refs, rerr = pr.profile_references(pr.ctx, "profile-runtime", "claude_one")
	testing.expect_value(
		t,
		rerr.code,
		domain.Error_Code.None,
	); testing.expect(t, strings.contains(refs, "profile-chain:profile-agent"))
	_, stored, err = iface.taskchain_save_lease(
		&tr,
		domain.Task_Lease {
			lease_id = "profile-lease",
			task_id = "profile-task",
			chain_id = "profile-chain",
			owner_user_id = "owner",
			holder_instance_id = "profile-instance",
			kind = "work",
			provider = "codex",
			provider_profile = "codex_two",
			model = "model",
			delivery = "wake",
		},
	)
	testing.expect(t, stored, err.message)
	lease, lease_found, le := iface.taskchain_get_lease(&tr, "profile-lease")
	testing.expect(
		t,
		lease_found,
		le.message,
	); testing.expect_value(t, lease.provider_profile, "codex_two")
	// Followups for two accounts of one driver remain separately durable.
	for id in ([]string{"claude_one", "claude_two"}) {
		created, create_err := iface.provider_extension_command_create(
			&pr,
			domain.Provider_Extension_Command {
				command_id = id,
				bridge_id = "profile-runtime",
				provider = "claude",
				profile_id = id,
				kind = "install",
				parent_id = "profile-update",
				state = "queued",
			},
		)
		testing.expect(t, created, create_err.message)
	}
	commands, ce := iface.provider_extension_command_list(&pr, "profile-runtime")
	testing.expect_value(t, ce.code, domain.Error_Code.None)
	testing.expect_value(t, len(commands), 2)
	if len(commands) == 2 do testing.expect(t, commands[0].profile_id != commands[1].profile_id)

}

@(test)
test_profiles_reconfiguration_commits_account_selection_atomically :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn: Conn
	impl: Agent_Repo_SQLite
	repo := reconfiguration_test_setup(t, &conn, &impl)
	defer close(&conn)
	inst, found, _ := iface.agent_get_instance(&repo, "inst_move")
	if !testing.expect(t, found) do return
	inst.provider_profile = "codex_one"
	saved, stored, err := iface.agent_save_instance(&repo, inst)
	if !testing.expect(t, stored, err.message) do return
	op := reconfiguration_test_op()
	op.expected_revision = saved.configuration_revision
	op.source.provider_profile = "codex_one"; op.destination.provider_profile = "claude_two"
	created, accepted, e := iface.instance_reconfiguration_begin(&repo, op)
	if !testing.expect(t, accepted, e.message) do return
	testing.expect_value(t, created.destination.provider_profile, "claude_two")
	op.phase = .Source_Stopped; op.source_stopped = true; op.revision = 2
	_, accepted, e = iface.instance_reconfiguration_advance(&repo, op, 1)
	if !testing.expect(t, accepted, e.message) do return
	op.phase = .Launching; op.destination_committed = true; op.revision = 3
	_, accepted, e = iface.instance_reconfiguration_advance(&repo, op, 2)
	if !testing.expect(t, accepted, e.message) do return
	committed, committed_found, _ := iface.agent_get_instance(&repo, "inst_move")
	testing.expect(
		t,
		committed_found,
	); testing.expect_value(t, committed.provider_profile, "claude_two"); testing.expect_value(t, committed.provider, "claude")
	_, stored, _ = iface.agent_save_instance(&repo, saved)
	testing.expect(t, !stored, "old runtime cannot overwrite the moved profile")
}
