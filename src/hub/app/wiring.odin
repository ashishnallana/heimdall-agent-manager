package app

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import bridge_log_service "odin_test:hub/service/bridge_log"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import shell_session_svc "odin_test:hub/service/shell_session"
import content_service "odin_test:hub/service/content"
import device_auth_service "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"
import push_service "odin_test:hub/service/push"
import search_service "odin_test:hub/service/search"
import taskchain_service "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import user_service "odin_test:hub/service/user"
import billing_service "odin_test:hub/service/billing"
import vault_directory_service "odin_test:hub/service/vault_directory"
import card_service "odin_test:hub/service/card"
import issue_service "odin_test:hub/service/issue"
import http "odin_test:hub/transport/http"
import platform "odin_test:hub/platform"

App_Graph :: struct {
	config: Hub_Config,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	bridge_runtime_registry: project_service.Bridge_Runtime_Registry,
	event_bus: events.User_Event_Bus,
	// attention_events coalesces card writes into attention_changed hints.
	attention_events: events.Attention_Debouncer,
	db: sqlite.Conn,
	sqlite_billing: sqlite.Billing_Repo_SQLite,
	billing_repo: iface.Billing_Repository,
	billing: billing_service.Service,
	billing_handlers: http.Billing_Handlers,
	sqlite_users: sqlite.User_Repo_SQLite,
	sqlite_bridges: sqlite.Bridge_Repo_SQLite,
	sqlite_bridge_commit: sqlite.Bridge_Enroll_Commit_Conn,
	sqlite_agents: sqlite.Agent_Repo_SQLite,
	sqlite_projects: sqlite.Project_Repo_SQLite,
	sqlite_content: sqlite.Content_Repo_SQLite,
	sqlite_taskchains: sqlite.Taskchain_Repo_SQLite,
	sqlite_search: sqlite.Search_Repo_SQLite,
	search_skills: []sqlite.Skill_Doc,
	sqlite_actions: sqlite.Action_Repo_SQLite,
	sqlite_scheduled_prompts: sqlite.Scheduled_Prompt_Repo_SQLite,
	sqlite_push: sqlite.Push_Repo_SQLite,
	sqlite_cards: sqlite.Card_Repo_SQLite,
	sqlite_attention: sqlite.Attention_Repo_SQLite,
	sqlite_issues: sqlite.Issue_Repo_SQLite,
	sqlite_shell_sessions: sqlite.Shell_Session_Repo_SQLite,
	sqlite_experiments: sqlite.Experiment_Repo_SQLite,
	sqlite_lsp_server_configs: sqlite.Lsp_Server_Config_Repo_SQLite,
	sqlite_providers: sqlite.Provider_Repo_SQLite,
	sqlite_vault_directory: sqlite.Vault_Directory_Repo_SQLite,
	sqlite_vault_directory_write: sqlite.Vault_Directory_Write_Conn,
	vault_directory_repo: iface.Vault_Directory_Repository,
	sqlite_bridge_logs: sqlite.Bridge_Log_Repo_SQLite,
	bridge_log_repo: iface.Bridge_Log_Repository,
	// bridge_log relay: queue + the one writer thread (started in build_graph,
	// joined in shutdown_graph).
	bridge_logs: bridge_log_service.Service,
	bridge_log_push: bridge_log_service.Push_Client,
	sqlite_uow_factory: sqlite.SQLite_Unit_Of_Work_Factory,
	repos: iface.Repositories,
	uow_factory: iface.Unit_Of_Work_Factory,
	users: user_service.User_Service,
	vault_directory: vault_directory_service.Service,
	bridge_update_catalog: bridge_service.Bridge_Update_Catalog,
	bridges: bridge_service.Bridge_Service,
	agents: agent_service.Agent_Service,
	projects: project_service.Project_Service,
	content: content_service.Content_Service,
	taskchains: taskchain_service.Taskchain_Service,
	task_engine: taskv2.Service,
	search: search_service.Search_Service,
	push: push_service.Push_Service,
	auth: auth_service.Auth_Service,
	device_auth_store: device_auth_service.Grant_Store,
	device_auth: device_auth_service.Device_Auth_Service,
	device_auth_handlers: http.Device_Auth_Handlers,
	user_handlers: http.User_Handlers,
	vault_directory_handlers: http.Vault_Directory_Handlers,
	bridge_handlers: http.Bridge_Handlers,
	agent_handlers: http.Agent_Handlers,
	project_handlers: http.Project_Handlers,
	content_handlers: http.Content_Handlers,
	taskchain_handlers: http.Taskchain_Handlers,
	search_handlers: http.Search_Handlers,
	skills_handlers: http.Skills_Handlers,
	push_handlers: http.Push_Handlers,
	agent_action_handlers: http.Agent_Action_Handlers,
	action_handlers: http.Action_Handlers,
	scheduled_prompt_handlers: http.Scheduled_Prompt_Handlers,
	cards: card_service.Card_Service,
	shell_session_repo: iface.Shell_Session_Repository,
	experiment_repo: iface.Experiment_Repository,
	lsp_server_config_repo: iface.Lsp_Server_Config_Repository,
	provider_repo: iface.Provider_Repository,
	shell_session_service: shell_session_svc.Shell_Session_Service,
	shell_session_stream_handlers: http.Shell_Session_Stream_Handlers,
	lsp_session_registry:          http.Lsp_Session_Registry,
	lsp_session_stream_handlers:   http.Lsp_Session_Stream_Handlers,
	shell_session_rest_handlers: http.Shell_Session_Rest_Handlers,
	experiment_handlers: http.Experiment_Rest_Handlers,
	lsp_server_config_handlers: http.Lsp_Server_Config_Rest_Handlers,
	provider_handlers: http.Provider_Handlers,
	providers: provider_service.Provider_Service,
	card_handlers: http.Card_Handlers,
	issues: issue_service.Issue_Service,
	issue_handlers: http.Issue_Handlers,
	action_mutex: sync.Mutex,
	action_bridge_versions: map[string]int,
	router: http.Router,
}

// task_engine_on_tasks_changed is the engine → taskchain callback: a task of the
// chain crossed into or out of a terminal state, so the chain's own status may
// need to follow (auto-complete when every task is done; reopen on a reopen).
task_engine_on_tasks_changed :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) {
	graph := (^App_Graph)(ctx)
	if graph == nil do return
	_, _, _ = taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, owner)
}

task_engine_on_instance_terminal :: proc(ctx: rawptr, instance_id: string) {
	taskv2.on_instance_terminal((^taskv2.Service)(ctx), instance_id)
}

task_engine_on_instance_activity :: proc(ctx: rawptr, instance_id, activity_status: string) {
	taskv2.on_instance_activity((^taskv2.Service)(ctx), instance_id, activity_status)
}

task_engine_on_user_stopped :: proc(ctx: rawptr, instance_id: string) {
	taskv2.on_instance_user_stopped((^taskv2.Service)(ctx), instance_id)
}

task_engine_on_start_success :: proc(ctx: rawptr, inst: domain.Agent_Instance) {
	taskv2.on_start_success((^taskv2.Service)(ctx), inst)
}

task_engine_on_unobserved_shell_terminal :: proc(ctx: rawptr, session: domain.Shell_Session) {
	svc := (^taskv2.Service)(ctx)
	if svc == nil || session.kind != "run" || !strings.has_prefix(session.label, taskv2.VERIFY_LABEL_PREFIX) do return
	duration := i64(0)
	if s_ms, sok := platform.rfc3339_to_unix_ms(session.started_at); sok {
		if e_ms, eok := platform.rfc3339_to_unix_ms(session.finished_at); eok && e_ms >= s_ms do duration = e_ms - s_ms
	}
	taskv2.on_verify_session_exited(svc, taskv2.Verify_Exit{
		session_id    = session.session_id,
		label         = session.label,
		owner_user_id = session.owner_user_id,
		status        = session.status,
		exit_code     = -1,
		exit_code_set = false,
		duration_ms   = duration,
		cmd           = session.cmd,
	})
}

build_graph :: proc(graph: ^App_Graph, config: Hub_Config) -> (bool, string) {
	graph.bridge_runtime_registry.limits = project_service.Runtime_Registry_Limits{
		live_bridges = config.runtime_max_live_bridges,
		live_bridges_per_owner = config.runtime_max_live_bridges_per_owner,
		active_instances = config.runtime_max_active_instances,
		active_instances_per_owner = config.runtime_max_active_instances_per_owner,
		terminal_instances_per_bridge = config.runtime_terminal_entries_per_bridge,
		terminal_retention = time.Duration(config.runtime_terminal_retention_seconds) * time.Second,
	}
	graph.config = config
	graph.clock = platform.real_clock()
	graph.ids = platform.real_id_generator()
	// In-process metrics registry + HTTP/process families. Always on (cheap
	// atomics); only the /metrics listener is gated by config.metrics_addr.
	init_metrics()
	project_service.fleet_metrics_set_registry(&graph.bridge_runtime_registry)

	db, db_ok, db_err := sqlite.open(config.database_path)
	if !db_ok do return false, db_err.message
	graph.db = db
	// Billing uses its own transactional connection; tolerate brief writer contention.
	if !sqlite.exec(&graph.db, "PRAGMA busy_timeout = 5000;") do return false, "failed to configure database busy timeout"
	// WAL (persistent, per database file): readers on the other connections no
	// longer block on — or get SQLITE_BUSY from — a committing writer, and a
	// commit is one WAL append instead of journal + db fsyncs. NORMAL is
	// durable across process crashes in WAL mode; only an OS crash can drop
	// the last commits. An in-memory test db reports "memory" and is unaffected.
	if !sqlite.exec(&graph.db, "PRAGMA journal_mode = WAL;") do return false, "failed to enable WAL journal mode"
	if !sqlite.exec(&graph.db, "PRAGMA synchronous = NORMAL;") do return false, "failed to configure database synchronous mode"

	migrations_ok, migration_err := sqlite.run_migrations(&graph.db, config.migrations_dir)
	if !migrations_ok do return false, migration_err.message
	// DB-backed metric collectors (users/bridges/subscriptions, 60 s cache) use
	// their own read-only connection; tables must exist first.
	_ = db_collectors_attach(config.database_path)

	// Reconcile drifted search (fts5) indexes on boot: a prior bad manual rebuild can
	// leave rows unindexed, which makes the external-content sync triggers' 'delete'
	// op raise SQLITE_CORRUPT and jam every UPDATE to those rows (frozen task status /
	// agent-instance heartbeats). Re-syncing here unsticks affected rows on deploy;
	// it is cheap when healthy (skips non-drifted indexes) and runtime writes also
	// self-heal via step_write_healing. Non-fatal: log and continue on failure.
	if rebuilt, reconcile_ok, reconcile_err := sqlite.repair_fts_indexes(&graph.db, true); !reconcile_ok {
		fmt.printfln("ham-hub FTS reconcile failed (search may be stale until repaired): %s", reconcile_err.message)
	} else if rebuilt > 0 {
		fmt.printfln("ham-hub FTS reconcile: re-synced %d drifted search index(es)", rebuilt)
	}

	if config.paddle_past_due_grace_seconds < 0 do return false, "Paddle grace period must be a nonnegative number of seconds"
	if config.paddle_environment != "sandbox" && config.paddle_environment != "live" do return false, "Paddle environment must be sandbox or live"
	billing_config := billing_service.Config{enforce_plan_limits = config.billing_enforce_plan_limits, hobbyist_price_id = config.paddle_hobbyist_price_id, environment = config.paddle_environment, api_key = config.paddle_api_key, client_token = config.paddle_client_token, webhook_secret = config.paddle_webhook_secret, past_due_grace_seconds = config.paddle_past_due_grace_seconds}
	billing_repo, billing_err := sqlite.new_billing_repository(&graph.sqlite_billing, config.database_path, config.paddle_environment, config.paddle_hobbyist_price_id, config.paddle_api_key != "" || config.paddle_webhook_secret != "")
	if billing_err.code != .None do return false, billing_err.message
	graph.billing_repo = billing_repo
	graph.billing = billing_service.Service{repo = &graph.billing_repo, clock = &graph.clock, config = billing_config}
	graph.billing_handlers = http.Billing_Handlers{auth = &graph.auth, billing = &graph.billing, ui_origin = config.ui_origin}

	graph.repos.users = sqlite.new_user_repository(&graph.sqlite_users, &graph.db)
	graph.repos.bridges = sqlite.new_bridge_repository(&graph.sqlite_bridges, &graph.db)
	// REQ-EA-2: the enrollment commit runs on its own connection (see
	// Bridge_Enroll_Commit_Conn). An in-memory database has no second connection.
	if config.database_path != ":memory:" {
		if ok, err := sqlite.open_bridge_enroll_commit_conn(&graph.sqlite_bridge_commit, config.database_path); !ok do return false, err.message
		graph.sqlite_bridges.commit = &graph.sqlite_bridge_commit
	}
	graph.repos.agents = sqlite.new_agent_repository(&graph.sqlite_agents, &graph.db)
	graph.repos.projects = sqlite.new_project_repository(&graph.sqlite_projects, &graph.db)
	graph.repos.content = sqlite.new_content_repository(&graph.sqlite_content, &graph.db)
	graph.repos.taskchains = sqlite.new_taskchain_repository(&graph.sqlite_taskchains, &graph.db)
	// Inject the compiled-in skills (slug + SKILL.md contents) into the search repo
	// so the skills provider can scan them without the repository importing the
	// agent service (keeps the repository below the service layer).
	graph.search_skills = make([]sqlite.Skill_Doc, len(agent_service.STATIC_SKILLS))
	for skill, i in agent_service.STATIC_SKILLS {
		graph.search_skills[i] = sqlite.Skill_Doc{slug = skill.slug, content = skill.content}
	}
	graph.repos.search = sqlite.new_search_repository(&graph.sqlite_search, &graph.db, graph.search_skills)
	graph.repos.actions = sqlite.new_action_repository(&graph.sqlite_actions, &graph.db)
	graph.repos.scheduled_prompts = graph.repos.actions
	graph.repos.push_subscriptions = sqlite.new_push_repository(&graph.sqlite_push, &graph.db)
	graph.repos.cards = sqlite.new_card_repository(&graph.sqlite_cards, &graph.db)
	graph.repos.attention = sqlite.new_attention_repository(&graph.sqlite_attention, &graph.db)
	graph.repos.issues = sqlite.new_issue_repository(&graph.sqlite_issues, &graph.db)
	graph.shell_session_repo = sqlite.new_shell_session_repository(&graph.sqlite_shell_sessions, &graph.db)
	graph.experiment_repo = sqlite.new_experiment_repository(&graph.sqlite_experiments, &graph.db)
	graph.lsp_server_config_repo = sqlite.new_lsp_server_config_repository(&graph.sqlite_lsp_server_configs, &graph.db)
	graph.bridge_log_repo = sqlite.new_bridge_log_repository(&graph.sqlite_bridge_logs, &graph.db)
	graph.bridge_logs = bridge_log_service.new_service(&graph.bridge_log_repo)
	if strings.trim_space(config.log_push_url) != "" {
		graph.bridge_log_push = bridge_log_service.new_push_client(config.log_push_url)
		bridge_log_service.install_push(&graph.bridge_logs, &graph.bridge_log_push)
	}
	graph.provider_repo = sqlite.new_provider_repository(&graph.sqlite_providers, &graph.db)
	// Passwordless vault directory: writes on their own connection (see
	// Vault_Directory_Write_Conn); an in-memory database has no second connection.
	if config.database_path != ":memory:" {
		if ok, err := sqlite.open_vault_directory_write_conn(&graph.sqlite_vault_directory_write, config.database_path); !ok do return false, err.message
		graph.vault_directory_repo = sqlite.new_vault_directory_repository(&graph.sqlite_vault_directory, &graph.db, &graph.sqlite_vault_directory_write)
	} else {
		graph.vault_directory_repo = sqlite.new_vault_directory_repository(&graph.sqlite_vault_directory, &graph.db)
	}
	graph.vault_directory = vault_directory_service.new_service(&graph.vault_directory_repo, &graph.clock)
	graph.uow_factory = sqlite.new_unit_of_work_factory(&graph.sqlite_uow_factory, &graph.db, &graph.repos)
	graph.users = user_service.new_user_service(&graph.repos.users, &graph.repos.agents, &graph.repos.projects, &graph.clock, &graph.ids)
	bridge_command_sink := bridge_runtime_service.new_bridge_command_sink(&graph.bridge_runtime_registry)
	graph.bridges = bridge_service.new_bridge_service_with_runtime(&graph.repos.bridges, bridge_command_sink, &graph.clock, &graph.ids)
	// REQ-IMPL-3 / audit F6: revocation must terminate the bridge's LIVE control
	// WebSocket, not merely flip a DB row. The registry owns the socket; the bridge
	// service must not reach into the transport layer, so the teardown is injected
	// as a seam here. Without this line revocation silently degrades to the F6
	// behaviour — the bridge stays connected and fully operational until it next
	// reconnects, which with proactive refresh may be never.
	bridge_service.with_connection_closer(&graph.bridges, bridge_runtime_service.new_bridge_connection_closer(&graph.bridge_runtime_registry))
	graph.bridges.catalog = &graph.bridge_update_catalog
	graph.agents = agent_service.new_agent_service_with_runtime(&graph.repos.agents, &graph.repos.bridges, &graph.repos.projects, &graph.repos.content, &graph.repos.taskchains, bridge_command_sink, &graph.bridge_runtime_registry, &graph.clock, &graph.ids)
	graph.agents.providers = &graph.provider_repo
	graph.projects = project_service.new_project_service_with_command_sink(&graph.repos.projects, &graph.repos.bridges, bridge_command_sink, &graph.clock, &graph.ids)
	graph.content = content_service.new_content_service_with_runtime(&graph.repos.content, &graph.repos.agents, &graph.repos.bridges, &graph.repos.projects, &graph.repos.taskchains, bridge_command_sink, &graph.clock, &graph.ids)
	graph.content.agent_configuration_service = &graph.agents
	graph.content.title_nudge_cooldown_seconds = config.title_nudge_cooldown_seconds
	graph.taskchains = taskchain_service.new_taskchain_service_with_runtime(&graph.repos.taskchains, &graph.repos.agents, bridge_command_sink, &graph.clock, &graph.ids)
	graph.taskchains.agent_service = &graph.agents
	graph.taskchains.event_bus = &graph.event_bus
	// Task System v2 engine: events + fold + leases + timers + matcher. Every
	// chain/task mutation in the taskchain service funnels into it; it calls back
	// (on_tasks_changed) so the chain auto-completes when its last task is done.
	graph.task_engine = taskv2.new_service(&graph.repos.taskchains, &graph.repos.agents, &graph.repos.bridges, &graph.clock, &graph.ids)
	graph.task_engine.uow_factory = &graph.uow_factory
	graph.task_engine.agent_service = &graph.agents
	graph.task_engine.bridge_command_sink = bridge_command_sink
	graph.task_engine.event_bus = &graph.event_bus
	graph.task_engine.on_tasks_changed = task_engine_on_tasks_changed
	graph.task_engine.on_tasks_changed_ctx = rawptr(graph)
	taskchain_service.set_engine(&graph.taskchains, &graph.task_engine)
	taskchain_service.set_uow_factory(&graph.taskchains, &graph.uow_factory)
	// Instance lifecycle → engine: ONE chokepoint for every death path
	// (taskv2.on_instance_terminal), busy/idle activity, and start-success.
	graph.agents.hooks = agent_service.Lifecycle_Hooks{
		ctx              = rawptr(&graph.task_engine),
		on_terminal      = task_engine_on_instance_terminal,
		on_activity      = task_engine_on_instance_activity,
		on_start_success = task_engine_on_start_success,
		on_user_stopped  = task_engine_on_user_stopped,
	}
	graph.search = search_service.new_search_service(&graph.repos.search)
	graph.push = push_service.new_push_service(&graph.repos.push_subscriptions, &graph.clock, &graph.ids, push_service.Vapid_Config{
		public_key = config.vapid_public_key,
		private_key = config.vapid_private_key,
		subject = config.vapid_subject,
	})
	graph.auth = auth_service.new_auth_service_with_tokens(auth_service.Trusted_Proxy_Config{
		username_header = config.username_header,
		display_name_header = config.display_name_header,
		email_header = config.email_header,
		trusted_proxy_cidrs = config.trusted_proxy_cidrs,
		auto_provision_users = config.auto_provision_users,
		login_url = config.login_url,
		logout_url = config.logout_url,
	}, &graph.users, &graph.repos.users, &graph.clock, &graph.ids)
	graph.auth.bridges = &graph.bridges
	graph.auth.agents = &graph.agents
	// Bridge-token authorization is ALWAYS enforced; there is nothing to wire.
	//
	// This line used to select the mode with `== "enforce"`, which made
	// enforcement conditional on an exact string match. Every other
	// value — unset, "Enforce", "enforced", "true", a typo — selected the
	// permissive mode silently, with no startup warning. REQ-IMPL-6 removed the
	// mode rather than hardening the comparison: a security control that can be
	// switched off by a misspelling in a config file should not be switchable.
	graph.device_auth_store = device_auth_service.new_grant_store(device_auth_service.Grant_Store_Config{
		verification_uri = config.ui_origin,
		expires_in = config.device_auth_expires_in,
		interval = config.device_auth_interval,
		rate_limit = config.device_auth_rate_limit,
		rate_window = config.device_auth_rate_window,
	})
	graph.device_auth = device_auth_service.new_device_auth_service(&graph.device_auth_store, device_auth_service.real_monotonic_clock(), config.trusted_proxy_cidrs)
	// Wire the device-flow token issuer (ELDA-4). The minter captures the graph
	// so approve() can pre-mint a no-revoke, no-cap device token on the bound
	// owner and the grant holds the plaintext for the first poll.
	device_auth_service.with_token_minter(&graph.device_auth, device_minter, rawptr(graph))
	// Wire the REQ-IMPL-2 bridge-credential issuer. Separate seam from the user
	// minter above: a grant that carried a bridge public key mints a per-machine
	// `brg_` identity, never a user token with the machine as a label.
	device_auth_service.with_bridge_token_minter(&graph.device_auth, device_bridge_minter, rawptr(graph))
	graph.users.bridges = &graph.repos.bridges
	graph.user_handlers = http.User_Handlers{launch_preferences = &graph.users, auth = &graph.auth, event_bus = &graph.event_bus, ws_tickets = http.new_user_ws_ticket_store()}
	graph.shell_session_service = shell_session_svc.new_shell_session_service(
		repo                = &graph.shell_session_repo,
		bridge_command_sink = bridge_command_sink,
		event_bus           = &graph.event_bus,
		ids                 = &graph.ids,
		clock               = &graph.clock,
		// REQ-SHELL-5: writes a run's single `shell_run` marker into the triggering
		// conversation. graph.content is constructed above, so the order holds.
		content             = &graph.content,
	)
	graph.shell_session_service.entitlements = billing_service.entitlement_lookup(&graph.billing)
	shell_session_svc.shell_metrics_set_service(&graph.shell_session_service)
	graph.shell_session_service.on_unobserved_terminal = task_engine_on_unobserved_shell_terminal
	graph.shell_session_service.on_unobserved_terminal_ctx = rawptr(&graph.task_engine)
	// REQ-SHELL-9 trigger A: a closed chain reaps its servers. Assigned HERE, after the
	// shell-session service is constructed, rather than next to the other two taskchain
	// dependencies at their construction above — graph.taskchains is built before this
	// service exists, so wiring it there would store a pointer to a zero value.
	graph.taskchains.shell_sessions = &graph.shell_session_service
	graph.shell_session_stream_handlers = http.Shell_Session_Stream_Handlers{
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		auth                = &graph.auth,
		ws_tickets          = &graph.user_handlers.ws_tickets,
		bridges             = &graph.bridges,
		shell_sessions      = &graph.shell_session_service,
		shell_repo          = &graph.shell_session_repo,
		bridge_command_sink = bridge_command_sink,
		experiments         = &graph.experiment_repo,
		preview_origin      = config.preview_origin,
		preview_legacy_path = config.preview_legacy_path,
		bridge_runtime_registry = &graph.bridge_runtime_registry,
	}
	// REQ-LSP-RLY-1. The registry is plain in-memory state: an LSP session lives
	// exactly as long as its browser socket, so there is no table and nothing to
	// reap on restart.
	graph.lsp_session_stream_handlers = http.Lsp_Session_Stream_Handlers{
		ws_tickets          = &graph.user_handlers.ws_tickets,
		bridges             = &graph.bridges,
		experiments         = &graph.experiment_repo,
		lsp_configs         = &graph.lsp_server_config_repo,
		sessions            = &graph.lsp_session_registry,
		ids                 = &graph.ids,
		bridge_command_sink = bridge_command_sink,
	}
	graph.shell_session_rest_handlers = http.Shell_Session_Rest_Handlers{
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		auth           = &graph.auth,
		shell_sessions = &graph.shell_session_service,
		preview_origin = config.preview_origin,
		ui_origin      = config.ui_origin,
		// REQ-SHELL-10 work item 3: read-only, to derive the bridge-offline session
		// state the serializer reports.
		bridge_runtime_registry = &graph.bridge_runtime_registry,
	}
	graph.bridge_handlers = http.Bridge_Handlers{
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		auth = &graph.auth,
		bridges = &graph.bridges,
		agents = &graph.agents,
		content = &graph.content,
		taskchains = &graph.taskchains,
		projects = &graph.projects,
		event_bus = &graph.event_bus,
		bridge_runtime_registry = &graph.bridge_runtime_registry,
		shell_sessions = &graph.shell_session_service,
		lsp_sessions = &graph.lsp_session_registry,
		providers = &graph.providers,
		bridge_logs = &graph.bridge_logs,
		task_engine = &graph.task_engine,
		vault = &graph.vault_directory,
	}
	graph.task_engine.vcs_show_file = http.bridge_vcs_show_file_callback
	graph.task_engine.vcs_show_file_ctx = rawptr(&graph.bridge_handlers)
	bridge_log_service.start(&graph.bridge_logs)
	graph.agent_handlers = http.Agent_Handlers{
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		launch_preferences = &graph.users,
		auth           = &graph.auth,
		agents         = &graph.agents,
		event_bus      = &graph.event_bus,
		ws_tickets     = &graph.user_handlers.ws_tickets,
		shell_sessions = &graph.shell_session_service,
		experiments    = &graph.experiment_repo,
	}
	graph.project_handlers = http.Project_Handlers{auth = &graph.auth, projects = &graph.projects}
	graph.content_handlers = http.Content_Handlers{auth = &graph.auth, agents = &graph.agents, content = &graph.content, event_bus = &graph.event_bus}
	graph.taskchain_handlers = http.Taskchain_Handlers{auth = &graph.auth, taskchains = &graph.taskchains, agents = &graph.agents, content = &graph.content, projects = &graph.projects, event_bus = &graph.event_bus, task_engine = &graph.task_engine, shell_sessions = &graph.shell_session_service}
	graph.search_handlers = http.Search_Handlers{auth = &graph.auth, search = &graph.search}
	graph.skills_handlers = http.Skills_Handlers{auth = &graph.auth}
	graph.push_handlers = http.Push_Handlers{auth = &graph.auth, push = &graph.push, vapid_public_key = config.vapid_public_key}
	graph.device_auth_handlers = http.Device_Auth_Handlers{service = &graph.device_auth, auth = &graph.auth, push = &graph.push, public_app_origin = config.public_app_origin, ui_origin = config.ui_origin, vault = &graph.vault_directory, event_bus = &graph.event_bus, pairing_hub_origins = config.pairing_hub_origin_list, bridges = &graph.bridges}
	graph.vault_directory_handlers = http.Vault_Directory_Handlers{auth = &graph.auth, vault = &graph.vault_directory, device_auth = &graph.device_auth, bridges = &graph.bridges, event_bus = &graph.event_bus, push = &graph.push, public_app_origin = config.public_app_origin}
	graph.agent_action_handlers = http.Agent_Action_Handlers{auth = &graph.auth, agents = &graph.agents, bridges = &graph.bridges, content = &graph.content, taskchains = &graph.taskchains, search = &graph.search, event_bus = &graph.event_bus, push = &graph.push, public_app_origin = config.public_app_origin, task_engine = &graph.task_engine}
	graph.action_bridge_versions = make(map[string]int)
	graph.action_handlers = http.Action_Handlers{
		auth = &graph.auth,
		agents = &graph.agents,
		bridges = &graph.bridges,
		content = &graph.content,
		repo = &graph.repos.actions,
		clock = &graph.clock,
		ids = &graph.ids,
		mutex = &graph.action_mutex,
		bridge_versions = &graph.action_bridge_versions,
	}
	graph.scheduled_prompt_handlers = graph.action_handlers
	graph.bridge_handlers.actions = rawptr(&graph.action_handlers)
	graph.bridge_handlers.scheduled_prompts = rawptr(&graph.action_handlers)
	graph.issues = issue_service.new_issue_service(&graph.repos.issues, &graph.clock, &graph.ids)
	graph.cards = card_service.new_card_service(
		&graph.repos.cards,
		&graph.repos.projects,
		&graph.taskchains,
		&graph.content,
		&graph.projects,
		&graph.agents,
		&graph.uow_factory,
		&graph.clock,
		&graph.ids,
		&graph.issues,
	)
	// Attention deck: the card projector keeps task-validation and actionable
	// message cards in step with their sources (write-through), so wire it into
	// the services that own those sources.
	card_service.init_attention(&graph.cards, &graph.repos.attention)
	taskchain_service.set_attention_notifier(&graph.taskchains, &graph.cards.attention_notifier)
	// The task engine re-projects the attention card of every task an event touched.
	graph.task_engine.attention = &graph.cards.attention_notifier
	content_service.set_attention_notifier(&graph.content, &graph.cards.attention_notifier)
	events.init_attention_debouncer(&graph.attention_events, &graph.event_bus)
	graph.cards.card_changed = card_service.Card_Changed_Hook{ctx = rawptr(&graph.attention_events), changed = attention_card_changed}
	graph.experiment_handlers = http.Experiment_Rest_Handlers{auth = &graph.auth, repo = &graph.experiment_repo, clock = &graph.clock}
	graph.lsp_server_config_handlers = http.Lsp_Server_Config_Rest_Handlers{auth = &graph.auth, repo = &graph.lsp_server_config_repo, clock = &graph.clock, ids = &graph.ids}
	graph.providers = provider_service.new_provider_service(&graph.provider_repo)
	graph.provider_handlers = http.Provider_Handlers{auth = &graph.auth, providers = &graph.providers, bridges = &graph.bridges, bridge_runtime_registry = &graph.bridge_runtime_registry, clock = &graph.clock, ids = &graph.ids, agents = &graph.agents}
	graph.agent_action_handlers.providers = &graph.providers
	graph.card_handlers = http.Card_Handlers{auth = &graph.auth, cards = &graph.cards, clock = &graph.clock}
	graph.issue_handlers = http.Issue_Handlers{auth = &graph.auth, issues = &graph.issues, clock = &graph.clock}
	graph.agent_action_handlers.cards = &graph.cards
	graph.router = http.new_router()
	register_routes(graph)
	// Log the Web Push send status ONCE at startup. Never log the private key.
	// When unconfigured, subscription endpoints still work; only sending is off.
	if vapid_is_configured(config) {
		fmt.println("ham-hub web push enabled (VAPID public key configured)")
	} else {
		fmt.println("ham-hub web push send disabled (no VAPID keypair configured); subscription endpoints remain active")
	}
	return true, ""
}

shutdown_graph :: proc(graph: ^App_Graph) {
	db_collectors_detach()
	// Join the bridge_log writer (final drain) while the DB is still open.
	bridge_log_service.service_free(&graph.bridge_logs)
	bridge_runtime_service.runtime_command_cache_destroy(&graph.bridge_runtime_registry)
	http.router_free(&graph.router)
	http.user_ws_ticket_store_free(&graph.user_handlers.ws_tickets)
	shell_session_svc.shell_metrics_detach_service(&graph.shell_session_service)
	shell_session_svc.shell_session_service_free(&graph.shell_session_service)
	device_auth_service.grant_store_free(&graph.device_auth_store)
	delete(graph.action_bridge_versions)
	billing_service.service_free(&graph.billing)
	sqlite.close(&graph.sqlite_billing.conn)
	sqlite.close(&graph.sqlite_bridge_commit.conn)
	vault_directory_service.service_free(&graph.vault_directory)
	sqlite.close(&graph.sqlite_vault_directory_write.conn)
	sqlite.close(&graph.db)
}

register_routes :: proc(graph: ^App_Graph) {
	http.router_add(&graph.router, "GET", "/api/v1/account/billing", rawptr(&graph.billing_handlers), http.account_billing_handler)
	http.router_add(&graph.router, "POST", "/api/v1/account/billing/checkout", rawptr(&graph.billing_handlers), http.account_checkout_handler)
	http.router_add(&graph.router, "POST", "/api/v1/account/billing/portal", rawptr(&graph.billing_handlers), http.account_portal_handler)
	http.router_add(&graph.router, "POST", "/api/v1/billing/paddle/webhook", rawptr(&graph.billing_handlers), http.paddle_webhook_handler)
	http.router_add(&graph.router, "GET", "/api/v1/health", rawptr(graph), health_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/authorize", rawptr(&graph.device_auth_handlers), http.device_authorize_handler)
	http.router_add(&graph.router, "GET", "/api/v1/device", rawptr(&graph.device_auth_handlers), http.device_page_handler)
	http.router_add(&graph.router, "GET", "/api/v1/device/add", rawptr(&graph.device_auth_handlers), http.device_add_redirect_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/verify", rawptr(&graph.device_auth_handlers), http.device_verify_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/pair-salts", rawptr(&graph.device_auth_handlers), http.device_pair_salts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/approve", rawptr(&graph.device_auth_handlers), http.device_approve_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/token", rawptr(&graph.device_auth_handlers), http.device_token_handler)
	// REQ-IMPL-3: credential rotation. Authenticated by the `hbf_` refresh token
	// itself — no user session, and an `hba_` access token is refused — so it is
	// registered next to the flow that issued the credential rather than under
	// /api/v1/bridges, whose routes are user-session scoped. Handled by
	// bridge_handlers because the credential is bridge-service state, not grant state.
	http.router_add(&graph.router, "POST", "/api/v1/device/bridge-refresh", rawptr(&graph.bridge_handlers), http.bridge_refresh_handler)
	http.router_add(&graph.router, "GET", "/api/v1/auth/config", rawptr(&graph.user_handlers), http.auth_config_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me", rawptr(&graph.user_handlers), http.me_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/logout-url", rawptr(&graph.user_handlers), http.logout_url_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/tokens", rawptr(&graph.user_handlers), http.list_my_tokens_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/tokens", rawptr(&graph.user_handlers), http.issue_my_token_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/tokens/*/revoke", rawptr(&graph.user_handlers), http.revoke_my_token_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/experiments", rawptr(&graph.experiment_handlers), http.experiment_list_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/me/experiments/*", rawptr(&graph.experiment_handlers), http.experiment_set_handler)
	http.router_add(&graph.router, "GET", "/api/v1/providers", rawptr(&graph.provider_handlers), http.provider_catalog_list_handler)
	http.router_add(&graph.router, "GET", "/api/v1/providers/*/icon", rawptr(&graph.provider_handlers), http.provider_icon_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/provider-status", rawptr(&graph.provider_handlers), http.bridge_provider_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/discover", rawptr(&graph.provider_handlers), http.bridge_provider_discover_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/bridges/*/providers/*", rawptr(&graph.provider_handlers), http.bridge_provider_enable_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/provider-tests", rawptr(&graph.provider_handlers), http.provider_test_start_handler)
	http.router_add(&graph.router, "GET", "/api/v1/provider-tests/*", rawptr(&graph.provider_handlers), http.provider_test_get_handler)
	http.router_add(&graph.router, "POST", "/api/v1/provider-tests/*/validate", rawptr(&graph.provider_handlers), http.provider_test_validate_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/provider-tests/*", rawptr(&graph.provider_handlers), http.provider_test_cancel_handler)
	// Passwordless vault device directory (plan §2 P2). Literal paths before wildcards.
	http.router_add(&graph.router, "GET", "/api/v1/vault/directory", rawptr(&graph.vault_directory_handlers), http.vault_directory_get_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/genesis", rawptr(&graph.vault_directory_handlers), http.vault_genesis_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/reset", rawptr(&graph.vault_directory_handlers), http.vault_reset_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/reset/cancel", rawptr(&graph.vault_directory_handlers), http.vault_reset_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/rotate", rawptr(&graph.vault_directory_handlers), http.vault_rotate_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/register", rawptr(&graph.vault_directory_handlers), http.vault_register_handler)
	http.router_add(&graph.router, "GET", "/api/v1/vault/devices/self", rawptr(&graph.vault_directory_handlers), http.vault_self_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/recovery", rawptr(&graph.vault_directory_handlers), http.vault_recovery_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/*/approve", rawptr(&graph.vault_directory_handlers), http.vault_approve_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/*/revoke", rawptr(&graph.vault_directory_handlers), http.vault_revoke_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/*/deny", rawptr(&graph.vault_directory_handlers), http.vault_deny_handler)
	// LSP server config CRUD (REQ-LSP-CFG-1). The /resolve literal route must be
	// registered before the /* wildcard so first-match-wins selects it correctly.
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/lsp-servers", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_create_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/lsp-servers", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_list_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/lsp-servers/resolve", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_resolve_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/lsp-servers/*", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_get_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridges/*/lsp-servers/*", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_delete_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/ws-ticket", rawptr(&graph.user_handlers), http.issue_user_ws_ticket_handler)
	http.router_add(&graph.router, "GET", "/api/v1/push/vapid-public-key", rawptr(&graph.push_handlers), http.vapid_public_key_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/push-subscriptions", rawptr(&graph.push_handlers), http.create_push_subscription_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/me/push-subscriptions", rawptr(&graph.push_handlers), http.delete_push_subscription_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/user-ws", rawptr(&graph.user_handlers), http.user_ws_upgrade_handler)
	http.router_add(&graph.router, "GET", "/api/v1/search", rawptr(&graph.search_handlers), http.search_handler)
	http.router_add(&graph.router, "GET", "/api/v1/skills/*", rawptr(&graph.skills_handlers), http.skill_detail_handler)
	http.router_add(&graph.router, "GET", "/api/v1/memories", rawptr(&graph.content_handlers), http.list_memories_handler)
	http.router_add(&graph.router, "POST", "/api/v1/memories", rawptr(&graph.content_handlers), http.create_memory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/memories/*", rawptr(&graph.content_handlers), http.memory_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/memories/*", rawptr(&graph.content_handlers), http.patch_memory_handler)
	http.router_add(&graph.router, "POST", "/api/v1/memories/*/*", rawptr(&graph.content_handlers), http.memory_action_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats", rawptr(&graph.content_handlers), http.list_chats_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats", rawptr(&graph.content_handlers), http.create_chat_handler)
	// Registered BEFORE the /chats/* wildcards so the literal "by-instance"
	// segment wins over "/chats/*/..." patterns (first-match-wins, equal segment
	// count). Resolves the single conversation for an agent instance id.
	http.router_add(&graph.router, "GET", "/api/v1/chats/by-instance/*", rawptr(&graph.content_handlers), http.get_chat_by_instance_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/chats/*", rawptr(&graph.content_handlers), http.patch_chat_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats/*/messages", rawptr(&graph.content_handlers), http.list_chat_messages_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/messages", rawptr(&graph.content_handlers), http.send_chat_message_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/pane-capture", rawptr(&graph.content_handlers), http.pane_capture_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/read", rawptr(&graph.content_handlers), http.read_chat_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts", rawptr(&graph.content_handlers), http.list_artifacts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/artifacts", rawptr(&graph.content_handlers), http.create_artifact_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*/content", rawptr(&graph.content_handlers), http.artifact_content_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*/download", rawptr(&graph.content_handlers), http.artifact_download_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.artifact_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.patch_artifact_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.delete_artifact_handler)
	http.router_add(&graph.router, "GET", "/api/v1/templates", rawptr(&graph.content_handlers), http.list_templates_handler)
	http.router_add(&graph.router, "POST", "/api/v1/templates", rawptr(&graph.content_handlers), http.create_template_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/templates/*", rawptr(&graph.content_handlers), http.update_template_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/templates/*", rawptr(&graph.content_handlers), http.delete_template_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances", rawptr(&graph.agent_handlers), http.list_agent_instances_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances", rawptr(&graph.agent_handlers), http.create_agent_instance_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/pane", rawptr(&graph.agent_handlers), http.get_agent_instance_pane_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/agent-instances/*/stream", rawptr(&graph.agent_handlers), http.agent_instance_stream_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/input", rawptr(&graph.agent_handlers), http.agent_instance_input_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/resize", rawptr(&graph.agent_handlers), http.agent_instance_resize_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/reconfigurations/retry", rawptr(&graph.agent_handlers), http.retry_instance_reconfiguration_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/reconfigurations", rawptr(&graph.agent_handlers), http.create_instance_reconfiguration_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/reconfigurations", rawptr(&graph.agent_handlers), http.list_instance_reconfigurations_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*", rawptr(&graph.agent_handlers), http.agent_instance_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agent-instances/*", rawptr(&graph.agent_handlers), http.patch_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/start", rawptr(&graph.agent_handlers), http.start_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/restart", rawptr(&graph.agent_handlers), http.restart_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/stop", rawptr(&graph.agent_handlers), http.stop_agent_instance_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/fs", rawptr(&graph.bridge_handlers), http.list_instance_dir_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/fs/file", rawptr(&graph.bridge_handlers), http.read_instance_file_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/conversation-launch", rawptr(&graph.user_handlers), http.get_conversation_launch_preferences_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/me/conversation-launch", rawptr(&graph.user_handlers), http.patch_conversation_launch_preferences_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/agents/*/favorite", rawptr(&graph.user_handlers), http.set_agent_favorite_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents", rawptr(&graph.agent_handlers), http.list_agents_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents", rawptr(&graph.agent_handlers), http.create_agent_handler)
	// Registered BEFORE the /agents/* wildcard so the literal "live" tree endpoint
	// (project -> live-chains -> agents) is not swallowed by agent_detail_handler.
	http.router_add(&graph.router, "GET", "/api/v1/agents/live", rawptr(&graph.taskchain_handlers), http.agents_live_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents/*", rawptr(&graph.agent_handlers), http.agent_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agents/*", rawptr(&graph.agent_handlers), http.update_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents/*/archive", rawptr(&graph.agent_handlers), http.archive_agent_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents/*/bridge-support", rawptr(&graph.agent_handlers), http.list_agent_support_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/agents/*/bridge-support", rawptr(&graph.agent_handlers), http.put_agent_support_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agents/*/bridge-support/*", rawptr(&graph.agent_handlers), http.patch_agent_support_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/agents/*/bridge-support/*", rawptr(&graph.agent_handlers), http.delete_agent_support_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects", rawptr(&graph.project_handlers), http.list_projects_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects", rawptr(&graph.project_handlers), http.create_project_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*", rawptr(&graph.project_handlers), http.project_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/projects/*", rawptr(&graph.project_handlers), http.update_project_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/archive", rawptr(&graph.project_handlers), http.archive_project_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/bridge-paths/*", rawptr(&graph.project_handlers), http.put_project_bridge_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/projects/*/bridge-paths/*", rawptr(&graph.project_handlers), http.delete_project_bridge_path_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/bridge-paths/*/validate", rawptr(&graph.project_handlers), http.validate_project_bridge_path_handler)
	// Project-scoped filesystem browser (resolves project -> bridge+root, relays fs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs", rawptr(&graph.bridge_handlers), http.list_project_dir_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs/quick-open", rawptr(&graph.bridge_handlers), http.quick_open_project_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs/search", rawptr(&graph.bridge_handlers), http.search_project_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.read_project_file_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.create_project_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.write_project_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/fs/files", rawptr(&graph.bridge_handlers), http.batch_write_project_files_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/fs/dir", rawptr(&graph.bridge_handlers), http.create_project_dir_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/fs/move", rawptr(&graph.bridge_handlers), http.move_project_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/projects/*/fs", rawptr(&graph.bridge_handlers), http.delete_project_path_handler)

	// Project-scoped VCS relay (resolves project -> bridge+root, relays vcs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/capabilities", rawptr(&graph.bridge_handlers), http.project_handle_vcs_capabilities)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/status", rawptr(&graph.bridge_handlers), http.project_handle_vcs_status)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/files", rawptr(&graph.bridge_handlers), http.project_handle_vcs_files)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/diff", rawptr(&graph.bridge_handlers), http.project_handle_vcs_diff)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/log", rawptr(&graph.bridge_handlers), http.project_handle_vcs_log)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/commit-diff", rawptr(&graph.bridge_handlers), http.project_handle_vcs_commit_diff)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/workspaces", rawptr(&graph.bridge_handlers), http.project_handle_vcs_workspaces)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/stage", rawptr(&graph.bridge_handlers), http.project_handle_vcs_stage)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/unstage", rawptr(&graph.bridge_handlers), http.project_handle_vcs_unstage)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/revert", rawptr(&graph.bridge_handlers), http.project_handle_vcs_revert)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/save-file", rawptr(&graph.bridge_handlers), http.project_handle_vcs_save_file)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/commit", rawptr(&graph.bridge_handlers), http.project_handle_vcs_commit)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/upload", rawptr(&graph.bridge_handlers), http.project_handle_vcs_upload)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/sync", rawptr(&graph.bridge_handlers), http.project_handle_vcs_sync)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains", rawptr(&graph.taskchain_handlers), http.list_task_chains_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/task-chain-search/documents", rawptr(&graph.taskchain_handlers), http.task_chain_search_documents_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains", rawptr(&graph.taskchain_handlers), http.create_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/search/relay", rawptr(&graph.bridge_handlers), http.task_chain_search_relay_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*", rawptr(&graph.taskchain_handlers), http.task_chain_detail_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/summary", rawptr(&graph.taskchain_handlers), http.get_task_chain_summary_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/summary", rawptr(&graph.taskchain_handlers), http.put_task_chain_summary_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/propose", rawptr(&graph.taskchain_handlers), http.propose_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/proposal/decide", rawptr(&graph.taskchain_handlers), http.decide_task_chain_proposal_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/publish", rawptr(&graph.taskchain_handlers), http.publish_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/complete", rawptr(&graph.taskchain_handlers), http.complete_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/pin", rawptr(&graph.taskchain_handlers), http.pin_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks", rawptr(&graph.taskchain_handlers), http.list_tasks_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks", rawptr(&graph.taskchain_handlers), http.create_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/publish", rawptr(&graph.taskchain_handlers), http.publish_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/review", rawptr(&graph.taskchain_handlers), http.user_review_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/reopen", rawptr(&graph.taskchain_handlers), http.reopen_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/answer", rawptr(&graph.taskchain_handlers), http.answer_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/verify", rawptr(&graph.taskchain_handlers), http.verify_task_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/fetch", rawptr(&graph.taskchain_handlers), http.fetch_task_ref_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/events", rawptr(&graph.taskchain_handlers), http.list_task_events_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/attempts/*/facets/*", rawptr(&graph.taskchain_handlers), http.get_task_facet_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*", rawptr(&graph.taskchain_handlers), http.patch_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/members", rawptr(&graph.taskchain_handlers), http.list_chain_members_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/members", rawptr(&graph.taskchain_handlers), http.add_chain_member_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/members/*", rawptr(&graph.taskchain_handlers), http.remove_chain_member_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories", rawptr(&graph.taskchain_handlers), http.list_chain_directories_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories", rawptr(&graph.taskchain_handlers), http.add_chain_directory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*", rawptr(&graph.taskchain_handlers), http.get_chain_directory_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*/directories/*", rawptr(&graph.taskchain_handlers), http.patch_chain_directory_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/directories/*", rawptr(&graph.taskchain_handlers), http.remove_chain_directory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/fleets", rawptr(&graph.taskchain_handlers), http.list_chain_fleets_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/fleets/*", rawptr(&graph.taskchain_handlers), http.upsert_chain_fleet_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/fleets/*", rawptr(&graph.taskchain_handlers), http.delete_chain_fleet_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/review-roles", rawptr(&graph.taskchain_handlers), http.list_chain_review_roles_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/review-roles/*", rawptr(&graph.taskchain_handlers), http.upsert_chain_review_role_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/review-roles/*", rawptr(&graph.taskchain_handlers), http.delete_chain_review_role_handler)
	// Task chain directory filesystem browser (resolves chain+directory -> bridge+path, relays fs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs", rawptr(&graph.bridge_handlers), http.list_chain_directory_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs/quick-open", rawptr(&graph.bridge_handlers), http.quick_open_chain_directory_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs/search", rawptr(&graph.bridge_handlers), http.search_chain_directory_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs/file", rawptr(&graph.bridge_handlers), http.read_chain_directory_file_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories/*/fs/file", rawptr(&graph.bridge_handlers), http.create_chain_directory_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/directories/*/fs/file", rawptr(&graph.bridge_handlers), http.write_chain_directory_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/directories/*/fs/files", rawptr(&graph.bridge_handlers), http.batch_write_chain_directory_files_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories/*/fs/dir", rawptr(&graph.bridge_handlers), http.create_chain_directory_dir_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories/*/fs/move", rawptr(&graph.bridge_handlers), http.move_chain_directory_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/directories/*/fs", rawptr(&graph.bridge_handlers), http.delete_chain_directory_path_handler)
	// Task chain directory VCS relay (resolves chain+directory -> bridge+path, relays vcs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/capabilities", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_capabilities)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/status", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_status)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/files", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_files)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/diff", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_diff)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/log", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_log)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/commit-diff", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_commit_diff)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/workspaces", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_workspaces)
	http.router_add(&graph.router, "GET", "/api/v1/workflows/templates", rawptr(&graph.taskchain_handlers), http.workflow_templates_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflows/definitions", rawptr(&graph.taskchain_handlers), http.workflow_list_definitions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflows/definitions", rawptr(&graph.taskchain_handlers), http.workflow_define_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflows/define", rawptr(&graph.taskchain_handlers), http.workflow_define_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/complete", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/scope", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/remove-dependency", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/depend", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/graph", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/complete", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/scope", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/remove-dependency", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/depend", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/work/graph", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflow-runs/*/cancel", rawptr(&graph.taskchain_handlers), http.workflow_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflow-runs/*/retry", rawptr(&graph.taskchain_handlers), http.workflow_retry_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflow-runs/*/executions", rawptr(&graph.taskchain_handlers), http.workflow_history_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflow-runs/*/output", rawptr(&graph.taskchain_handlers), http.workflow_output_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflow-runs/*", rawptr(&graph.taskchain_handlers), http.workflow_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/workflow-runs", rawptr(&graph.taskchain_handlers), http.workflow_run_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/workflow-runs", rawptr(&graph.taskchain_handlers), http.workflow_runs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*", rawptr(&graph.taskchain_handlers), http.get_task_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*/tasks/*", rawptr(&graph.taskchain_handlers), http.patch_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/cancel", rawptr(&graph.taskchain_handlers), http.cancel_task_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/comments", rawptr(&graph.taskchain_handlers), http.list_task_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/comments", rawptr(&graph.taskchain_handlers), http.create_task_comment_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/send-to-user", rawptr(&graph.agent_action_handlers), http.agent_action_chat_send_to_user_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/send-to-agent", rawptr(&graph.agent_action_handlers), http.agent_action_chat_send_to_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/fetch", rawptr(&graph.agent_action_handlers), http.agent_action_chat_fetch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/read", rawptr(&graph.agent_action_handlers), http.agent_action_chat_read_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/conversation/set-title", rawptr(&graph.agent_action_handlers), http.agent_action_conversation_set_title_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/set-title", rawptr(&graph.agent_action_handlers), http.agent_action_chain_set_title_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/set-description", rawptr(&graph.agent_action_handlers), http.agent_action_chain_set_description_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/set-status", rawptr(&graph.agent_action_handlers), http.agent_action_chain_set_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/show", rawptr(&graph.agent_action_handlers), http.agent_action_chain_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/summary", rawptr(&graph.agent_action_handlers), http.agent_action_chain_summary_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/summary/set", rawptr(&graph.agent_action_handlers), http.agent_action_chain_summary_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/propose", rawptr(&graph.agent_action_handlers), http.agent_action_chain_propose_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/templates", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_templates_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/list", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/define", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_define_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/run", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_run_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/runs", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_runs_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/history", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_history_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/status", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/output", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_output_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/retry", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_retry_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/cancel", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/agents/live", rawptr(&graph.agent_action_handlers), http.agent_action_agents_live_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/context", rawptr(&graph.agent_action_handlers), http.agent_action_context_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/list", rawptr(&graph.agent_action_handlers), http.agent_action_task_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/show", rawptr(&graph.agent_action_handlers), http.agent_action_task_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/comments", rawptr(&graph.agent_action_handlers), http.agent_action_task_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/create", rawptr(&graph.agent_action_handlers), http.agent_action_task_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/update", rawptr(&graph.agent_action_handlers), http.agent_action_task_update_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/depend", rawptr(&graph.agent_action_handlers), http.agent_action_task_depend_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/comment", rawptr(&graph.agent_action_handlers), http.agent_action_task_comment_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/next", rawptr(&graph.agent_action_handlers), http.agent_action_lease_next_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/heartbeat", rawptr(&graph.agent_action_handlers), http.agent_action_lease_heartbeat_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/submit", rawptr(&graph.agent_action_handlers), http.agent_action_lease_submit_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/handoff", rawptr(&graph.agent_action_handlers), http.agent_action_lease_handoff_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/switch", rawptr(&graph.agent_action_handlers), http.agent_action_lease_switch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/block", rawptr(&graph.agent_action_handlers), http.agent_action_lease_block_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/review/post", rawptr(&graph.agent_action_handlers), http.agent_action_review_post_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/task/fetch", rawptr(&graph.agent_action_handlers), http.agent_action_task_fetch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/create", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/list", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/show", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/content", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_content_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/search", rawptr(&graph.agent_action_handlers), http.agent_action_search_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/propose", rawptr(&graph.agent_action_handlers), http.agent_action_memory_propose_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/list", rawptr(&graph.agent_action_handlers), http.agent_action_memory_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/show", rawptr(&graph.agent_action_handlers), http.agent_action_memory_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/content", rawptr(&graph.agent_action_handlers), http.agent_action_memory_content_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/create", rawptr(&graph.agent_action_handlers), http.agent_action_card_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/list", rawptr(&graph.agent_action_handlers), http.agent_action_card_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/show", rawptr(&graph.agent_action_handlers), http.agent_action_card_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/discard", rawptr(&graph.agent_action_handlers), http.agent_action_card_discard_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/accept", rawptr(&graph.agent_action_handlers), http.agent_action_card_accept_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/start-success", rawptr(&graph.agent_action_handlers), http.agent_action_start_success_handler)
	// REQ-ENROLL-9: the four pre-shared-token enrollment routes are GONE —
	// POST/GET /api/v1/bridge-enrollments, DELETE /api/v1/bridge-enrollments/*
	// (enrollment-token minting, listing and revocation) and
	// POST /api/v1/bridges/enroll (the token-for-credential exchange).
	// Enrollment is browser-approved only; see the /api/v1/device/* routes.
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/bridge-ws", rawptr(&graph.bridge_handlers), http.bridge_ws_upgrade_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/agent-instances/*/bootstrap", rawptr(&graph.bridge_handlers), http.bridge_instance_bootstrap_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/agents/*/bootstrap-manifest", rawptr(&graph.bridge_handlers), http.bridge_agent_manifest_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/blobs/*", rawptr(&graph.bridge_handlers), http.bridge_blob_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/blobs", rawptr(&graph.bridge_handlers), http.bridge_blobs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges", rawptr(&graph.bridge_handlers), http.list_bridges_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/shells/*/input", rawptr(&graph.bridge_handlers), http.bridge_shell_input_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/shells/*/resize", rawptr(&graph.bridge_handlers), http.bridge_shell_resize_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/fs", rawptr(&graph.bridge_handlers), http.list_bridge_dir_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/fs/stat", rawptr(&graph.bridge_handlers), http.stat_bridge_path_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/fs/mkdir", rawptr(&graph.bridge_handlers), http.mkdir_bridge_path_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*", rawptr(&graph.bridge_handlers), http.bridge_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/bridges/*", rawptr(&graph.bridge_handlers), http.rename_bridge_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/revoke", rawptr(&graph.bridge_handlers), http.revoke_bridge_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/update", rawptr(&graph.bridge_handlers), http.bridge_update_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/unseal", rawptr(&graph.bridge_handlers), http.bridge_unseal_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/public-key", rawptr(&graph.bridge_handlers), http.bridge_public_key_handler)
	// REQ-EA: pending-enrollment status for the approval page, and operator cancel.
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/enrollment", rawptr(&graph.bridge_handlers), http.bridge_enrollment_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/enrollment/cancel", rawptr(&graph.bridge_handlers), http.bridge_enrollment_cancel_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/events", rawptr(&graph.bridge_handlers), http.bridge_events_list_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridges/*/events", rawptr(&graph.bridge_handlers), http.bridge_events_purge_handler)
	// Actions API
	http.router_add(&graph.router, "GET", "/api/v1/actions", rawptr(&graph.action_handlers), http.list_actions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/actions", rawptr(&graph.action_handlers), http.create_action_handler)
	http.router_add(&graph.router, "GET", "/api/v1/actions/*", rawptr(&graph.action_handlers), http.get_action_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/actions/*", rawptr(&graph.action_handlers), http.patch_action_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/actions/*", rawptr(&graph.action_handlers), http.delete_action_handler)
	http.router_add(&graph.router, "POST", "/api/v1/actions/*/run", rawptr(&graph.action_handlers), http.run_action_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/actions", rawptr(&graph.action_handlers), http.bridge_list_actions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/actions/*/execute", rawptr(&graph.action_handlers), http.bridge_execute_action_handler)

	// Scheduled Prompts backward compatibility
	http.router_add(&graph.router, "GET", "/api/v1/scheduled-prompts", rawptr(&graph.action_handlers), http.list_scheduled_prompts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/scheduled-prompts", rawptr(&graph.action_handlers), http.create_scheduled_prompt_handler)
	http.router_add(&graph.router, "GET", "/api/v1/scheduled-prompts/*", rawptr(&graph.action_handlers), http.get_scheduled_prompt_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/scheduled-prompts/*", rawptr(&graph.action_handlers), http.patch_scheduled_prompt_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/scheduled-prompts/*", rawptr(&graph.action_handlers), http.delete_scheduled_prompt_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/scheduled-prompts", rawptr(&graph.action_handlers), http.bridge_list_scheduled_prompts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/scheduled-prompts/*/execute", rawptr(&graph.action_handlers), http.bridge_execute_scheduled_prompt_handler)

	// Cards API
	http.router_add(&graph.router, "GET", "/api/v1/attention", rawptr(&graph.card_handlers), http.attention_handler)
	http.router_add(&graph.router, "GET", "/api/v1/attention/summary", rawptr(&graph.card_handlers), http.attention_summary_handler)
	http.router_add(&graph.router, "GET", "/api/v1/cards", rawptr(&graph.card_handlers), http.list_cards_handler)
	http.router_add(&graph.router, "POST", "/api/v1/cards", rawptr(&graph.card_handlers), http.create_card_handler)
	http.router_add(&graph.router, "GET", "/api/v1/cards/*", rawptr(&graph.card_handlers), http.get_card_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/cards/*", rawptr(&graph.card_handlers), http.patch_card_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/cards/*", rawptr(&graph.card_handlers), http.delete_card_handler)
	http.router_add(&graph.router, "POST", "/api/v1/cards/*/*", rawptr(&graph.card_handlers), http.card_action_handler)

	// Issues API
	http.router_add(&graph.router, "GET", "/api/v1/issues", rawptr(&graph.issue_handlers), http.list_issues_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues", rawptr(&graph.issue_handlers), http.create_issue_handler)
	http.router_add(&graph.router, "GET", "/api/v1/issues/*", rawptr(&graph.issue_handlers), http.get_issue_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/issues/*", rawptr(&graph.issue_handlers), http.patch_issue_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/issues/*", rawptr(&graph.issue_handlers), http.delete_issue_handler)
	http.router_add(&graph.router, "GET", "/api/v1/issues/*/comments", rawptr(&graph.issue_handlers), http.list_issue_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues/*/comments", rawptr(&graph.issue_handlers), http.create_issue_comment_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/issues/*/comments/*", rawptr(&graph.issue_handlers), http.delete_issue_comment_handler)
	http.router_add(&graph.router, "GET", "/api/v1/issues/*/votes", rawptr(&graph.issue_handlers), http.list_issue_votes_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues/*/vote", rawptr(&graph.issue_handlers), http.vote_issue_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/issues/*/vote", rawptr(&graph.issue_handlers), http.unvote_issue_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues/*/unvote", rawptr(&graph.issue_handlers), http.unvote_issue_handler)

	// Shell session WS stream + HTTP input/resize fallback (T7).
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/shells/*/stream", rawptr(&graph.shell_session_stream_handlers), http.shell_session_stream_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/lsp/*/stream", rawptr(&graph.lsp_session_stream_handlers), http.lsp_session_stream_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/input", rawptr(&graph.shell_session_stream_handlers), http.shell_session_input_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/resize", rawptr(&graph.shell_session_stream_handlers), http.shell_session_resize_handler)
	// Preview tunnel proxy (T8) — raw-socket route: handler owns the socket for all
	// request methods (plain HTTP and future WebSocket upgrade via XM-2).
	http.router_add_raw_upgrade(&graph.router, "ANY", "/api/v1/preview/**", rawptr(&graph.shell_session_stream_handlers), http.shell_session_preview_proxy_handler)
	// Shell session REST API (T5).
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_create_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_list_by_bridge_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_list_by_project_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_list_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*", rawptr(&graph.shell_session_rest_handlers), http.shell_session_get_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/shells/*", rawptr(&graph.shell_session_rest_handlers), http.shell_session_kill_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/signal", rawptr(&graph.shell_session_rest_handlers), http.shell_session_signal_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/restart", rawptr(&graph.shell_session_rest_handlers), http.shell_session_restart_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/port", rawptr(&graph.shell_session_rest_handlers), http.shell_session_set_port_handler)
	// REQ-SHELL-2 §3: convert a live FOREGROUND run to background at runtime. The
	// control REQ-SHELL-6 builds in the UI calls this; it is also the shape the
	// agent-liveness hook uses, so both go through one transition.
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/background", rawptr(&graph.shell_session_rest_handlers), http.shell_session_background_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*/log", rawptr(&graph.shell_session_rest_handlers), http.shell_session_log_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*/capture", rawptr(&graph.shell_session_rest_handlers), http.shell_session_capture_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*/pane", rawptr(&graph.shell_session_rest_handlers), http.shell_session_pane_handler)
}

health_handler :: proc(ctx: rawptr, req: http.Request) -> http.Response {
	graph := (^App_Graph)(ctx)
	server_time := platform.clock_now(&graph.clock)
	return http.respond_success("{\"ok\":true,\"version\":1}", req.request_id, server_time)
}

// device_minter is the task-3 token issuer wired into approve (ELDA-4). It
// issues a user API token via the device-authorization path (no revoke, no cap,
// created_from='device_authorization') and returns the plaintext + token_id so
// the grant can hand it out on the first successful /device/token poll.
device_minter :: proc(graph_ptr: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	graph := (^App_Graph)(graph_ptr)
	token, plaintext, ok, _ := auth_service.issue_device_authorization_token(&graph.auth, domain.User_ID(user_id), device_label)
	return plaintext, token.token_id, ok
}

// device_bridge_minter is the REQ-IMPL-2 bridge-credential issuer wired into
// approve. Unlike device_minter above — which issues a USER token whose only
// identity is owner_user_id, with the machine as a free-text label — this mints
// a `brg_` row and a credential that resolves to exactly that one bridge, so
// verify_bridge_token / resolve_bridge_instance_auth give per-machine scoping.
// Returns (plaintext_token, bridge_id, ok).
device_bridge_minter :: proc(graph_ptr: rawptr, req: device_auth_service.Bridge_Mint_Request) -> (device_auth_service.Bridge_Mint_Result, bool) {
	graph := (^App_Graph)(graph_ptr)
	// Passwordless vault gate (plan §2 P2): a bridge enrolls only into an existing
	// vault directory, and only with an approving device's signed `approve`
	// statement naming the bridge's persistent identity key. Validated BEFORE the
	// credential is minted; committed (versioned CAS) right after, and a failed
	// commit cancels the still-pending enrollment so no unattested bridge remains.
	if !req.vault_approval.present {
		return device_auth_service.Bridge_Mint_Result{
			error = domain.domain_error(.Validation_Failed, "approving a bridge requires a signed vault_approval from an approved device"),
		}, false
	}
	approval_in := vault_directory_service.Bridge_Approval_Input{
		user_id = req.owner_user_id,
		expected_version = req.vault_approval.expected_version,
		statement = req.vault_approval.statement,
		signature = req.vault_approval.signature,
		bridge_identity_public_key = req.bridge_identity_public_key,
	}
	vault_device, check_err := vault_directory_service.check_bridge_approval(&graph.vault_directory, approval_in)
	if check_err.code != .None do return device_auth_service.Bridge_Mint_Result{error = check_err}, false
	result, ok, mint_err := bridge_service.enroll_bridge_from_device_grant(&graph.bridges, bridge_service.Device_Enroll_Input{
		owner_user_id = req.owner_user_id, // bound from Auth_Context by approve()
		bridge_public_key = req.bridge_public_key,
		bridge_key_fingerprint = req.bridge_key_fingerprint,
		os_user = req.os_user,
		machine_hostname = req.device_label,
		machine_os = req.os,
		bridge_version = req.app_version,
		new_bridge_label = req.new_bridge_label,
		// REQ-BE-3: the approver's "reuse this bridge" choice. Empty mints a new
		// bridge; non-empty attaches, and the bridge service re-checks that the
		// approver owns the target and that it is neither revoked nor pending.
		target_bridge_id = req.target_bridge_id,
		// REQ-EA-1: the enrollment stays pending until the vault key is delivered.
		pending = true,
	})
	if !ok {
		// Pass ownership/target refusals through (e.g. an attach target that is not
		// the approver's): they are the approver's to see, not an internal fault.
		if mint_err.code == .Not_Found || mint_err.code == .Validation_Failed {
			return device_auth_service.Bridge_Mint_Result{error = mint_err}, false
		}
		return device_auth_service.Bridge_Mint_Result{}, false
	}
	if _, commit_err := vault_directory_service.commit_bridge_approval(&graph.vault_directory, approval_in, vault_device, result.bridge.bridge_id); commit_err.code != .None {
		// Roll back exactly the family just minted. cancel_pending_enrollment would pick
		// the bridge's newest enroll family, which for an attach refused because another
		// attach is already pending could be THAT attach's family (same-second tie).
		_, _, _ = bridge_service.rollback_pending_enrollment(&graph.bridges, result.bridge.bridge_id, result.family_id)
		return device_auth_service.Bridge_Mint_Result{error = commit_err}, false
	}
	// REQ-IMPL-3: enroll_bridge_from_device_grant returns an EXPIRING PAIR
	// (`hba_` + `hbf_`), so the approval hands both halves to the grant and the
	// bridge receives them together on its single-use poll.
	return device_auth_service.Bridge_Mint_Result{
		access_token = result.bridge_token,
		refresh_token = result.refresh_token,
		bridge_id = result.bridge.bridge_id,
		expires_in = result.expires_in,
		refresh_expires_in = result.refresh_expires_in,
		vault_delivery_expected = true,
	}, true
}

// attention_card_changed adapts the card service's change hook to the
// debounced attention_changed event (one hint per owner per 500ms).
attention_card_changed :: proc(ctx: rawptr, owner_user_id: string, kind: string) {
	events.attention_debouncer_note((^events.Attention_Debouncer)(ctx), owner_user_id, kind)
}
