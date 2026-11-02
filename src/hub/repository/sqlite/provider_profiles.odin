package sqlite

import "core:c"
import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"

PROFILE_COLUMNS :: "bridge_id,profile_id,provider,label_enc,accent,enabled,has_config_dir,has_home_path,has_shadow_home_path,has_binary,env_count,args_count,custom_models_count,state,created_at,updated_at"
bridge_provider_profiles_list_sqlite :: proc(
	ctx: rawptr,
	bridge_id: string,
) -> (
	[dynamic]domain.Bridge_Provider_Profile,
	domain.Domain_Error,
) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return nil, domain.domain_error(.Internal_Error, "profile repository unavailable")
	stmt: sqlite3_stmt
	query :=
		"SELECT " +
		PROFILE_COLUMNS +
		" FROM bridge_provider_profiles WHERE bridge_id=? ORDER BY profile_id;"
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "profile list failed")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	out := make([dynamic]domain.Bridge_Provider_Profile)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(
			&out,
			domain.Bridge_Provider_Profile {
				bridge_id = column_text(stmt, 0),
				profile_id = column_text(stmt, 1),
				provider = column_text(stmt, 2),
				label_enc = column_text(stmt, 3),
				accent = column_text(stmt, 4),
				enabled = column_text_unowned(stmt, 5) == "1",
				has_config_dir = column_text_unowned(stmt, 6) == "1",
				has_home_path = column_text_unowned(stmt, 7) == "1",
				has_shadow_home_path = column_text_unowned(stmt, 8) == "1",
				has_binary = column_text_unowned(stmt, 9) == "1",
				env_count = provider_rank_from_stmt(stmt, 10),
				args_count = provider_rank_from_stmt(stmt, 11),
				custom_models_count = provider_rank_from_stmt(stmt, 12),
				state = column_text(stmt, 13),
				created_at = sqlite3_column_int64(stmt, 14),
				updated_at = sqlite3_column_int64(stmt, 15),
			},
		)
	}
	return out, {}
}

// A fleet with inherited bridge placement can run on this bridge and also retains
// its profile. Terminal instances do not prevent removal.
bridge_provider_profile_references_sqlite :: proc(
	ctx: rawptr,
	bridge_id, profile_id: string,
) -> (
	string,
	domain.Domain_Error,
) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return "", domain.domain_error(.Internal_Error, "profile repository unavailable")
	stmt: sqlite3_stmt
	query := "SELECT 'agent',agent_instance_id FROM agent_instances WHERE bridge_id=? AND provider_profile=? AND runtime_status NOT IN ('stopped','failed','exited','terminated') UNION ALL SELECT 'fleet',f.task_chain_id || ':' || f.agent_id FROM task_chain_fleets f JOIN task_chains c ON c.chain_id=f.task_chain_id JOIN bridges b ON b.bridge_id=? WHERE ((f.provider_profile=? AND (f.bridge_id=? OR f.bridge_id='')) OR EXISTS (SELECT 1 FROM json_each(f.bridge_models_json) j WHERE j.key=? AND COALESCE(NULLIF(json_extract(j.value,'$.provider_profile'),''),json_extract(j.value,'$.provider'))=?)) AND c.owner_user_id=b.owner_user_id;"
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return "", domain.domain_error(.Internal_Error, "profile reference query failed")
	defer sqlite3_finalize(stmt)
	bind_text(
		stmt,
		1,
		bridge_id,
	); bind_text(stmt, 2, profile_id); bind_text(stmt, 3, bridge_id); bind_text(stmt, 4, profile_id); bind_text(stmt, 5, bridge_id); bind_text(stmt, 6, bridge_id); bind_text(stmt, 7, profile_id)
	agents, fleets :=
		make([dynamic]string, context.temp_allocator),
		make([dynamic]string, context.temp_allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		if column_text_unowned(stmt, 0) ==
		   "agent" {append(&agents, strings.clone(column_text_unowned(stmt, 1), context.temp_allocator))} else {append(&fleets, strings.clone(column_text_unowned(stmt, 1), context.temp_allocator))}
	}
	bytes, err := json.marshal(struct {
			agents, fleets: []string,
		}{agents[:], fleets[:]}, allocator = context.temp_allocator)
	if err != nil do return "", domain.domain_error(.Internal_Error, "profile references encoding failed")
	return string(bytes), {}
}

bridge_provider_profiles_reconcile_sqlite :: proc(
	ctx: rawptr,
	bridge_id: string,
	profiles: []domain.Bridge_Provider_Profile,
) -> domain.Domain_Error {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return domain.domain_error(.Internal_Error, "profile repository unavailable")
	// Hold SQLite's recursive connection mutex for the entire savepoint: readers
	// and other writes cannot observe or join a half-reconciled report.
	mu := sqlite3_db_mutex(impl.conn.db); sqlite3_mutex_enter(mu); defer sqlite3_mutex_leave(mu)
	if !exec(impl.conn, "SAVEPOINT provider_profiles_report;") do return domain.domain_error(.Internal_Error, "profile reconciliation unavailable")
	committed := false
	defer if !committed {_ = exec(impl.conn, "ROLLBACK TO provider_profiles_report; RELEASE provider_profiles_report;")}
	previous, err := bridge_provider_profiles_list_sqlite(ctx, bridge_id)
	if err.code != .None do return err
	defer domain.bridge_provider_profiles_destroy(previous)
	for p in profiles {
		stmt: sqlite3_stmt
		query :=
			"INSERT INTO bridge_provider_profiles (" +
			PROFILE_COLUMNS +
			") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(bridge_id,profile_id) DO UPDATE SET provider=excluded.provider,label_enc=excluded.label_enc,accent=excluded.accent,enabled=excluded.enabled,has_config_dir=excluded.has_config_dir,has_home_path=excluded.has_home_path,has_shadow_home_path=excluded.has_shadow_home_path,has_binary=excluded.has_binary,env_count=excluded.env_count,args_count=excluded.args_count,custom_models_count=excluded.custom_models_count,state=excluded.state,created_at=excluded.created_at,updated_at=excluded.updated_at;"
		if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "profile upsert prepare failed")
		bind_text(
			stmt,
			1,
			bridge_id,
		); bind_text(stmt, 2, p.profile_id); bind_text(stmt, 3, p.provider); bind_text(stmt, 4, p.label_enc); bind_text(stmt, 5, p.accent)
		sqlite3_bind_int(
			stmt,
			6,
			1 if p.enabled else 0,
		); sqlite3_bind_int(stmt, 7, 1 if p.has_config_dir else 0); sqlite3_bind_int(stmt, 8, 1 if p.has_home_path else 0); sqlite3_bind_int(stmt, 9, 1 if p.has_shadow_home_path else 0); sqlite3_bind_int(stmt, 10, 1 if p.has_binary else 0)
		sqlite3_bind_int(
			stmt,
			11,
			c.int(p.env_count),
		); sqlite3_bind_int(stmt, 12, c.int(p.args_count)); sqlite3_bind_int(stmt, 13, c.int(p.custom_models_count)); bind_text(stmt, 14, p.state)
		sqlite3_bind_int64(stmt, 15, p.created_at); sqlite3_bind_int64(stmt, 16, p.updated_at)
		rc := sqlite3_step(stmt); sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "profile upsert failed")
	}
	for p in previous {
		present := false
		for item in profiles do if item.profile_id == p.profile_id do present = true
		if present do continue
		refs, rerr := bridge_provider_profile_references_sqlite(ctx, bridge_id, p.profile_id)
		if rerr.code != .None do return rerr
		// Parse only our own encoded references, never bridge-authored fields.
		parsed: struct {
			agents, fleets: []string,
		}
		if json.unmarshal_string(refs, &parsed, allocator = context.temp_allocator) != nil do return domain.domain_error(.Internal_Error, "profile references invalid")
		used := len(parsed.agents) + len(parsed.fleets) > 0
		query := "DELETE FROM bridge_provider_profiles WHERE bridge_id=? AND profile_id=?;"
		if used do query = "UPDATE bridge_provider_profiles SET state='missing',enabled=0 WHERE bridge_id=? AND profile_id=?;"
		stmt: sqlite3_stmt
		if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "profile prune failed")
		bind_text(stmt, 1, bridge_id); bind_text(stmt, 2, p.profile_id)
		rc := sqlite3_step(stmt); sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "profile prune failed")
		// Old account observations must not survive a removed/recreated profile ID.
		for table in ([]string{"bridge_provider_status", "bridge_provider_models", "bridge_provider_settings"}) {
			q := strings.concatenate(
				{"DELETE FROM ", table, " WHERE bridge_id=? AND profile_id=?;"},
				context.temp_allocator,
			)
			st: sqlite3_stmt
			if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &st, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "profile observations prune failed")
			bind_text(
				st,
				1,
				bridge_id,
			); bind_text(st, 2, p.profile_id); rc = sqlite3_step(st); sqlite3_finalize(st)
			if rc != SQLITE_DONE do return domain.domain_error(.Internal_Error, "profile observations prune failed")
		}
	}
	if !exec(impl.conn, "RELEASE provider_profiles_report;") do return domain.domain_error(.Internal_Error, "profile reconciliation commit failed")
	committed = true
	return {}
}
