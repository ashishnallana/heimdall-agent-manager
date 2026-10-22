package sqlite

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"

// Every migration is embedded straight from its .sql file with #load, so the
// embedded copy and the on-disk copy in migrations/ are the same bytes by
// construction. Keep it that way: never transcribe a migration's SQL into a
// string literal here. run_migrations falls back to these constants whenever
// migrations_dir does not resolve -- which is what a packaged binary run
// outside the repo does -- and a hand-copied literal that drifts from its file
// silently bootstraps a fresh database onto a stale schema (BUG-14).
MIGRATION_001_FOUNDATION :: #load("migrations/001_foundation.sql", string)
MIGRATION_002_OWNER_SCOPED_CORE :: #load("migrations/002_owner_scoped_core.sql", string)

// MIGRATION_003_DEVICE_TOKENS is the embedded fallback for the token-provenance
// migration (ELDA-4). The canonical source is
// src/hub/repository/sqlite/migrations/003_device_tokens.sql.
MIGRATION_003_DEVICE_TOKENS :: #load("migrations/003_device_tokens.sql", string)

MIGRATION_004_DEFAULT_SKILL_MEMORY :: #load("migrations/004_default_skill_memory.sql", string)

MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY :: #load(
	"migrations/005_agent_to_agent_cross_chain_memory.sql",
	string,
)

MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY :: #load(
	"migrations/006_live_agents_skill_memory.sql",
	string,
)

MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT :: #load(
	"migrations/007_hide_agent_to_agent_from_user_chat.sql",
	string,
)

MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY :: #load(
	"migrations/008_read_inbound_messages_skill_memory.sql",
	string,
)

MIGRATION_009_ARTIFACT_METADATA :: #load("migrations/009_artifact_metadata.sql", string)

MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY :: #load(
	"migrations/010_artifact_usage_skill_memory.sql",
	string,
)

MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY :: #load(
	"migrations/011_artifact_download_skill_memory.sql",
	string,
)

MIGRATION_012_TASK_CHAINS_V2 :: #load("migrations/012_task_chains_v2.sql", string)

MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY :: #load(
	"migrations/013_task_workflow_skill_memory.sql",
	string,
)

MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS :: #load(
	"migrations/014_task_workflow_skill_comments.sql",
	string,
)

MIGRATION_015_MEMORY_TARGET_SCOPE :: #load("migrations/015_memory_target_scope.sql", string)

MIGRATION_018_COORDINATOR_MEMBER_BACKFILL :: #load(
	"migrations/018_coordinator_member_backfill.sql",
	string,
)

MIGRATION_017_CHAT_MESSAGE_TYPES :: #load("migrations/017_chat_message_types.sql", string)

MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY :: #load(
	"migrations/016_memory_workflow_skill_memory.sql",
	string,
)

MIGRATION_019_CURRENT_TASK_AND_PRIORITY :: #load(
	"migrations/019_current_task_and_priority.sql",
	string,
)

// MIGRATION_020_TITLE_TRACKING adds per-run auto-title tracking fields to
// conversations and task chains, plus a per-agent monotonic counter table used
// to mint default titles of the form "<agent-name> #<n>". The embedded fallback
// mirrors src/hub/repository/sqlite/migrations/020_title_tracking.sql.
MIGRATION_020_TITLE_TRACKING :: #load("migrations/020_title_tracking.sql", string)

// MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME adds human-readable display_name
// support to agent_instances, defaulting to "<agent-name> #<n>".
MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME :: #load(
	"migrations/021_agent_instance_display_name.sql",
	string,
)

// MIGRATION_022_SCHEDULED_PROMPTS adds the scheduled_prompts table for
// delayed and recurring prompt injection into agent instances.
MIGRATION_022_SCHEDULED_PROMPTS :: #load("migrations/022_scheduled_prompts.sql", string)

// MIGRATION_023_ACTIONS creates the actions table with recurring-schedule fields,
// replacing scheduled_prompts and migrating existing rows.
MIGRATION_023_ACTIONS :: #load("migrations/023_actions.sql", string)

// MIGRATION_024_PUSH_SUBSCRIPTIONS creates the push_subscriptions table storing
// per-user browser Web Push subscriptions (WP-STORE-1). endpoint is unique so a
// re-subscribe upserts the keys; owner_user_id is immutable via a trigger.
MIGRATION_024_PUSH_SUBSCRIPTIONS :: #load("migrations/024_push_subscriptions.sql", string)

// Mirrors src/hub/repository/sqlite/migrations/025_lookup_indexes.sql — see that
// file for why each index exists.
MIGRATION_025_LOOKUP_INDEXES :: #load("migrations/025_lookup_indexes.sql", string)

// MIGRATION_026_MEMORY_SCOPE_LISTS converts memory targeting from single scalar
// scope columns (agent_id/project_id/template_id/bridge_id) to JSON-array list
// columns (agent_ids/project_ids/template_ids/bridge_ids). An empty list ('[]')
// means "applies to all" for that dimension; a non-empty list means the value
// must be a member. It backfills each list from the prior scalar (empty scalar
// -> '[]', non-empty -> a single-element array) and then drops the scalars. The
// earlier seed migrations (004/013/016) still insert the scalar columns, which
// this migration folds into the lists — the list columns do not exist until this
// point, so the append-only ledger requires the backfill here rather than
// rewriting those historical seeds. Scope ids are safe identifier tokens
// (agt_/proj_/tmpl_/brg_), so simple JSON string quoting is sufficient.
MIGRATION_026_MEMORY_SCOPE_LISTS :: #load("migrations/026_memory_scope_lists.sql", string)

// MIGRATION_027_DEFAULT_COORDINATOR_AGENT seeds a durable 'coordinator' agent for
// every existing user that lacks one and remaps agents off the removed built-in
// 'System Reviewer' template onto the default 'tmpl_empty'. Idempotent via the
// NOT EXISTS guard + deterministic agent_id and the template WHERE clause. Kept
// byte-identical to 027_default_coordinator_agent.sql.
MIGRATION_027_DEFAULT_COORDINATOR_AGENT :: #load(
	"migrations/027_default_coordinator_agent.sql",
	string,
)

// MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP adds first-class description to
// memories and deletes legacy seeded system memories in favor of static skills.
MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP :: #load(
	"migrations/028_memory_description_and_cleanup.sql",
	string,
)

// MIGRATION_029_SEARCH_FTS_COMMENTS adds an external-content FTS5 index over
// task_comments.body so comment search is tokenized + multi-word + relevance-
// ranked (retiring the LIKE '%q%' full scan). Embedded via #load of the on-disk
// twin so the copy is byte-identical BY CONSTRUCTION (no hand-copy drift).
// Idempotent (IF NOT EXISTS + 'rebuild' backfill); run_migrations skips it (marking
// applied) when FTS5 is unavailable or the vtable already exists, so non-FTS builds
// still boot on the indexed-LIKE fallback.
MIGRATION_029_SEARCH_FTS_COMMENTS :: #load("migrations/029_search_fts_comments.sql", string)

// MIGRATION_030_SEARCH_FTS_ALL broadens the SEARCH-6 FTS5 foundation to every
// text-bearing scope (conversations/agents/agent_instances/task-chains/tasks/
// projects/artifacts/memories) as per-table external-content FTS5 vtables + sync
// triggers + idempotent backfill. It is embedded via #load of the on-disk twin so
// the embedded copy is byte-identical BY CONSTRUCTION (no hand-copy drift). Same
// boot-safe guard as 029: skipped (marked applied) when FTS5 is unavailable or the
// vtables already exist, so non-FTS builds boot on the indexed-LIKE fallback.
MIGRATION_030_SEARCH_FTS_ALL :: #load("migrations/030_search_fts_all.sql", string)

// MIGRATION_031_SEARCH_FTS_MESSAGES adds an external-content FTS5 index over
// chat_messages.body (MSG-1) so chat MESSAGE content is searchable (previously only
// conversation titles were indexed). Same wiring/guard as 029/030; the backfill
// uses the correct 'rebuild' op (the 'WHERE rowid NOT IN' guard is a no-op on
// external-content, which is why 029/030's backfill was fixed to 'rebuild' too).
MIGRATION_031_SEARCH_FTS_MESSAGES :: #load("migrations/031_search_fts_messages.sql", string)

// MIGRATION_032_AI_NATIVE_TEMPLATES seeds built-in AI-native role templates into
// the templates table: coordinator, worker, reviewer, and empty system templates.
MIGRATION_032_AI_NATIVE_TEMPLATES :: #load("migrations/032_ai_native_templates.sql", string)

// MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT seeds canonical durable
// agents (coordinator, worker, reviewer) and the dedicated Conversation project for all users.
MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT :: #load(
	"migrations/033_default_agents_and_conversation_project.sql",
	string,
)

// MIGRATION_034_CARDS creates the cards table, indexes, and owner-immutable trigger
// for Curator action cards (REQ-CARD-1).
MIGRATION_034_CARDS :: #load("migrations/034_cards.sql", string)

// MIGRATION_035_CURATOR_TEMPLATE seeds the built-in Curator system template
// (tmpl_curator) for activity-driven Action Cards (REQ-AGENT-1).
MIGRATION_035_CURATOR_TEMPLATE :: #load("migrations/035_curator_template.sql", string)

// MIGRATION_036_ACTION_TARGETS adds target_agent_id, target_bridge_id, target_provider,
// target_model, target_project_id to actions table (REQ-SCHED-1).
MIGRATION_036_ACTION_TARGETS :: #load("migrations/036_action_targets.sql", string)

// MIGRATION_037_PROJECT_STATE adds the soft-archive `state` column to projects
// (mirrors the agents `state` column). Default 'active'; archiving is reversible.
MIGRATION_037_PROJECT_STATE :: #load("migrations/037_project_state.sql", string)

// MIGRATION_038_ACTION_INSTANCE_STRATEGY adds instance_strategy + last_spawned_instance_id
// to actions (REQ-SCHED-2). Defaults keep existing rows on the legacy "reuse" behavior.
MIGRATION_038_ACTION_INSTANCE_STRATEGY :: #load(
	"migrations/038_action_instance_strategy.sql",
	string,
)

// MIGRATION_039_SHELL_JOBS adds the shell_jobs table tracking bridge-executed shell
// commands (REQ-15). Status/metadata only — command output lives on the bridge host
// and is never stored in the hub.
MIGRATION_039_SHELL_JOBS :: #load("migrations/039_shell_jobs.sql", string)

// MIGRATION_040_ARTIFACT_LIST_INDEXES creates composite covering indexes on the
// artifacts table for fast filtering and pagination (REQ-ARTIFACT-DB-INDEXES).
MIGRATION_040_ARTIFACT_LIST_INDEXES :: #load("migrations/040_artifact_list_indexes.sql", string)

// MIGRATION_041_SHELL_SESSIONS creates the shell_sessions table replacing
// shell_jobs as the unified session concept (REQ-SH-CONTRACT §1).
MIGRATION_041_SHELL_SESSIONS :: #load("migrations/041_shell_sessions.sql", string)

// MIGRATION_042_PINNED_TASK_CHAINS adds is_pinned and pinned_at to task_chains.
MIGRATION_042_PINNED_TASK_CHAINS :: #load("migrations/042_pinned_task_chains.sql", string)

// MIGRATION_043_EXPERIMENTS creates the experiments table for Hub-persisted
// feature flags (REQ-EXP-1). One row per (owner_user_id, key) pair.
MIGRATION_043_EXPERIMENTS :: #load("migrations/043_experiments.sql", string)

// MIGRATION_044_LSP_SERVERS creates the lsp_server_configs table for
// Hub-persisted LSP server configurations (REQ-LSP-CFG-1). Unique on
// (owner_user_id, bridge_id, language, dir_prefix).
MIGRATION_044_LSP_SERVERS :: #load("migrations/044_lsp_servers.sql", string)

// MIGRATION_043_TASK_CHAIN_DIRECTORIES creates the task_chain_directories table
// storing extra relevant directories for a task chain (REQ-BE-TASK-CHAIN-RELEVANT-DIRECTORIES).
MIGRATION_043_TASK_CHAIN_DIRECTORIES :: #load("migrations/043_task_chain_directories.sql", string)

// MIGRATION_044_ISSUES creates issues, issue_comments, and issue_votes tables (REQ-ISSUES-BACKEND-SCHEMA-SERVICE).
MIGRATION_044_ISSUES :: #load("migrations/044_issues.sql", string)

// MIGRATION_045_LSP_SERVER_PATTERNS adds dir_pattern to lsp_server_configs (REQ-LSP-DIR-PAT-1).
MIGRATION_045_LSP_SERVER_PATTERNS :: #load("migrations/045_lsp_server_patterns.sql", string)

// MIGRATION_046_TASK_CHAIN_FLEETS creates task_chain_fleets table for role-based
// agent instance pooling (REQ-FLEET-SCHEMA-1).
MIGRATION_046_TASK_CHAIN_FLEETS :: #load("migrations/046_task_chain_fleets.sql", string)


// MIGRATION_048_TASK_SUBSCRIPTIONS creates task_subscriptions table for
// reactive status event fanout (REQ-TCC-2).
MIGRATION_048_TASK_SUBSCRIPTIONS :: #load("migrations/048_task_subscriptions.sql", string)

// MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY collapses shell_sessions.kind to
// run|shell|server (dropping the dead 'agent' rows) and rebuilds the table with
// PRIMARY KEY (bridge_id, session_id) so one bridge cannot overwrite another's
// row (REQ-SHELL-1 §1, §7).
MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY :: #load(
	"migrations/048_shell_sessions_kind_and_key.sql",
	string,
)

// MIGRATION_049_SHELL_SESSIONS_BACKGROUND_AND_CONVERSATION adds the two columns
// explicit backgrounding needs on the row: `background` (REQ-SHELL-2 deletes the
// implicit 15s rule, so foreground/background becomes a stored property rather
// than an elapsed-time accident) and `conversation_id` (the TRIGGERING
// conversation, which REQ-SHELL-5 scopes the completion marker to and REQ-SHELL-6
// filters on).
MIGRATION_049_SHELL_SESSIONS_BACKGROUND_AND_CONVERSATION :: #load(
	"migrations/049_shell_sessions_background_and_conversation.sql",
	string,
)

// MIGRATION_050_SHELL_SESSIONS_KILL_INTENT adds kill_requested_at (REQ-SHELL-3):
// the durable record that a kill was ACCEPTED for a session. Before it, a kill
// requested while the bridge was offline failed and persisted nothing, so nothing
// re-issued it on reconnect and the process ran forever. With it the accept
// succeeds, the intent survives the disconnect, and the hub replays outstanding
// intents when the bridge's WS comes back.
MIGRATION_050_SHELL_SESSIONS_KILL_INTENT :: #load(
	"migrations/050_shell_sessions_kill_intent.sql",
	string,
)

// MIGRATION_051_SHELL_SESSIONS_RUN_SEQ adds run_seq (REQ-SHELL-4): which RUN of a
// session an exit report is about. A durable exit outbox can deliver an exit after
// the session has been restarted under the same session_id, and without this the
// hub would mark a live session terminal on a stale exit. See the migration file.
MIGRATION_051_SHELL_SESSIONS_RUN_SEQ :: #load("migrations/051_shell_sessions_run_seq.sql", string)

// MIGRATION_052_DROP_SHELL_JOBS drops the shell_jobs table (REQ-SHELL-7). The whole
// shell_jobs stack — domain type, service, repository, routes and UI — is deleted in
// the same commit; 039 created the table, 041 replaced the CONCEPT with
// shell_sessions but left the table behind, and this removes it. Metadata only, no
// output column, so nothing recoverable is lost. See the migration file.
MIGRATION_052_DROP_SHELL_JOBS :: #load("migrations/052_drop_shell_jobs.sql", string)

// MIGRATION_053_BRIDGE_VERSION_AND_UPDATES adds version, commit_sha, build_timestamp, update_status, and update_error to bridges (REQ-BUPD-1).
MIGRATION_053_BRIDGE_VERSION_AND_UPDATES :: #load(
	"migrations/053_bridge_version_and_updates.sql",
	string,
)

// MIGRATION_054_BRIDGE_TELEMETRY adds telemetry_enabled to bridges (REQ-TEL-1).
MIGRATION_054_BRIDGE_TELEMETRY :: #load("migrations/054_bridge_telemetry.sql", string)

// MIGRATION_055_MEMORY_ACTION_EXPIRY adds expires_at to memories and backfills
// pending memories and cards to expire 24h after creation (REQ-EXPIRY-SCHEMA-1).
MIGRATION_055_MEMORY_ACTION_EXPIRY :: #load("migrations/055_memory_action_expiry.sql", string)

// MIGRATION_056_BRIDGE_VAULT_STATUS adds vault_status to bridges (REQ-BVS-1): the
// bridge's self-reported "unlocked"/"locked", defaulting to '' for a bridge
// that has never reported one. UX indicator only; nothing gates on it.
MIGRATION_056_BRIDGE_VAULT_STATUS :: #load("migrations/056_bridge_vault_status.sql", string)

// MIGRATION_057_BRIDGE_TOKENS creates bridge_tokens, the expiring `hba_`/`hbf_`
// credential pair plus the rotation lineage that makes refresh-token reuse
// detectable (REQ-IMPL-3 / design §7.4). See the .sql file for why the lineage
// needs its own table rather than more columns on `bridges`.
MIGRATION_057_BRIDGE_TOKENS :: #load("migrations/057_bridge_tokens.sql", string)

// MIGRATION_058_PROVIDER_CATALOG seeds the Hub-owned recipes, literal model ids,
// catalog etag, and locally served icon bytes (REQ-PROVIDER-CATALOG-1).
MIGRATION_058_PROVIDER_CATALOG :: #load("migrations/058_provider_catalog.sql", string)

MIGRATION_059_BRIDGE_PROVIDER_STATE :: #load("migrations/059_bridge_provider_state.sql", string)
MIGRATION_060_EXPLICIT_PROVIDER_MODELS :: #load(
	"migrations/060_explicit_provider_models.sql",
	string,
)
MIGRATION_061_CODEX_LAUNCH_RECIPE :: #load("migrations/061_codex_launch_recipe.sql", string)
MIGRATION_062_CLAUDE_STARTUP_DETECTION :: #load(
	"migrations/062_claude_startup_detection.sql",
	string,
)
MIGRATION_063_CLAUDE_LOGIN_METHOD_DETECTION :: #load(
	"migrations/063_claude_login_method_detection.sql",
	string,
)
MIGRATION_064_CODEX_TRUST_DETECTION :: #load(
	"migrations/064_codex_trust_detection.sql",
	string,
)
MIGRATION_065_ANTIGRAVITY_LAUNCH_RECIPE :: #load(
	"migrations/065_antigravity_launch_recipe.sql",
	string,
)
MIGRATION_066_ANTIGRAVITY_TRUST_DETECTION :: #load(
	"migrations/066_antigravity_trust_detection.sql",
	string,
)
MIGRATION_067_CODEX_SANDBOX_AND_MODELS :: #load(
	"migrations/067_codex_sandbox_and_models.sql",
	string,
)
MIGRATION_068_REPAIR_PROVIDER_CATALOG_ETAG :: #load(
	"migrations/068_repair_provider_catalog_etag.sql",
	string,
)

MIGRATION_069_ACCOUNT_BILLING :: #load("migrations/069_account_billing.sql", string)

MIGRATION_070_FREE_ONE_BRIDGE :: #load("migrations/070_free_one_bridge.sql", string)

MIGRATION_072_INSTANCE_RECONFIGURATION :: #load("migrations/072_instance_reconfiguration.sql", string)

MIGRATION_071_CODEX_FOLDER_ACCESS_TRUST :: #load("migrations/071_codex_folder_access_trust.sql", string)
MIGRATION_072_BRIDGE_UPDATE_PROGRESS :: #load("migrations/072_bridge_update_progress.sql", string)

MIGRATION_073_CLAUDE_CURRENT_MODELS :: #load("migrations/073_claude_current_models.sql", string)

MIGRATION_074_RECONFIGURATION_RECOVERY_STOP :: #load("migrations/074_reconfiguration_recovery_stop.sql", string)

MIGRATION_076_FLEET_BRIDGE_MODELS :: #load("migrations/076_fleet_bridge_models.sql", string)

MIGRATION_077_SOLOIST_AGENT :: #load("migrations/077_soloist_agent.sql", string)

MIGRATION_078_DROP_STALE_BUILTIN_TEMPLATE_ROWS :: #load("migrations/078_drop_stale_builtin_template_rows.sql", string)

MIGRATION_079_REPAIR_PROVIDER_CATALOG_ETAG :: #load("migrations/079_repair_provider_catalog_etag.sql", string)

MIGRATION_080_COPILOT_LAUNCH_RECIPE :: #load("migrations/080_copilot_launch_recipe.sql", string)

MIGRATION_081_ANTIGRAVITY_MODELS :: #load("migrations/081_antigravity_models.sql", string)

MIGRATION_082_PI_PROVIDER :: #load("migrations/082_pi_provider.sql", string)

MIGRATION_083_TASK_CHAIN_SEARCH_FEED :: #load("migrations/083_task_chain_search_feed.sql", string)

MIGRATION_084_BRIDGE_LOG_EVENTS :: #load("migrations/084_bridge_log_events.sql", string)

MIGRATION_085_AGENT_INSTANCE_LAST_ERROR :: #load("migrations/085_agent_instance_last_error.sql", string)

MIGRATION_086_CLAUDE_BYPASS_PERMISSIONS_DETECTION :: #load("migrations/086_claude_bypass_permissions_detection.sql", string)

MIGRATION_087_ATTENTION_CARDS :: #load("migrations/087_attention_cards.sql", string)
// MIGRATION_088_BRIDGE_ENROLLMENT_PENDING adds enrollment_pending_until
// to bridges (REQ-EA-1): a bridge is pending until its vault key is delivered.
MIGRATION_088_BRIDGE_ENROLLMENT_PENDING :: #load("migrations/088_bridge_enrollment_pending.sql", string)
// MIGRATION_089_MEMORY_PROPOSER records who proposed a memory and on which
// chain (attention deck memory cards).
MIGRATION_089_MEMORY_PROPOSER :: #load("migrations/089_memory_proposer.sql", string)

// MIGRATION_090_TASK_V2 is the Task System v2 cutover: the event-sourced engine
// tables (task_events/attempts/facets/leases/reviews, chain_summaries,
// workflow_definitions), the new task/chain/fleet columns, and the one-shot
// legacy status → state / reviewer-ref → fleet-role data migration. The legacy
// columns and tables are dropped afterwards by upgrade_task_v2_schema.
MIGRATION_090_TASK_V2 :: #load("migrations/090_task_v2.sql", string)

// 091: agent_instances.stopped_by — a user stop sticks (Task System v2 F4).
MIGRATION_091_AGENT_INSTANCE_STOPPED_BY :: #load("migrations/091_agent_instance_stopped_by.sql", string)

// 092: passwordless vault device directory (vault_directories, vault_devices,
// vault_epochs, vault_wrapped_keyrings). Idempotent; re-run by upgrade_vault_directory_schema.
MIGRATION_092_VAULT_DEVICE_DIRECTORY :: #load("migrations/092_vault_device_directory.sql", string)

// 093: drops the pre-log vault tables (no backward compatibility; dev data wiped).
// upgrade_vault_directory_schema re-creates them from 092 (signed-log shape).
MIGRATION_093_VAULT_SIGNED_LOG :: #load("migrations/093_vault_signed_log.sql", string)

// 094: hub-blind pairing; drops the vault tables (no backward compatibility) and
// upgrade_vault_directory_schema re-creates them from 092 (pair_lookup, no user_code).
MIGRATION_094_VAULT_HUB_BLIND_PAIRING :: #load("migrations/094_vault_hub_blind_pairing.sql", string)
// MIGRATION_096_DROP_PASSWORD_VAULT removes the password-era vault table (the
// passwordless vault replaced it; no backward compatibility). Migration
// 047 that created it is gone from the order and the tree.
MIGRATION_096_DROP_PASSWORD_VAULT :: #load("migrations/096_drop_password_vault.sql", string)

// 095: pairing stretch (pair_salt on pending devices); drops the vault tables (no
// backward compatibility) and upgrade_vault_directory_schema re-creates them from 092.
MIGRATION_095_VAULT_PAIRING_STRETCH :: #load("migrations/095_vault_pairing_stretch.sql", string)

MIGRATION_075_CONVERSATION_LAUNCH_PREFERENCES :: #load("migrations/075_conversation_launch_preferences.sql", string)

MIGRATION_097_WORKFLOW_RUNS :: #load("migrations/097_workflow_runs.sql", string)

MIGRATION_098_MIXED_WORK_GRAPH :: #load("migrations/098_mixed_work_graph.sql", string)

MIGRATION_099_MIXED_WORK_EXECUTION :: #load("migrations/099_mixed_work_execution.sql", string)

// 100: the pending device's declared pairing hub origin (vault_devices.pair_hub_origin).
// An ALTER (keeps existing vault data); fresh databases get the column from 092.
MIGRATION_100_VAULT_PAIR_HUB_ORIGIN :: #load("migrations/100_vault_pair_hub_origin.sql", string)

// 101: Codex/Pi GPT-6 models (codex-cli 0.162); retires the GPT-5.6 rows.
MIGRATION_101_CODEX_GPT6_MODELS :: #load("migrations/101_codex_gpt6_models.sql", string)

// 102: drops the never-used bridge_enrollments table from 002 and its owner trigger.
MIGRATION_102_DROP_BRIDGE_ENROLLMENTS :: #load("migrations/102_drop_bridge_enrollments.sql", string)
MIGRATION_103_PLAN_ENFORCEMENT :: #load("migrations/103_plan_enforcement.sql", string)

// 106: agents.permission_mode ('yolo' default | 'ask'); 'ask' launches without
// the catalog yolo_args (REQ-EXT-PERM-2). 104/105 are reserved for the extension
// events and provider extension migrations landing on sibling branches.
MIGRATION_106_AGENT_PERMISSION_MODE :: #load("migrations/106_agent_permission_mode.sql", string)

migration_order :: [107]string {
	"001_foundation.sql",
	"002_owner_scoped_core.sql",
	"003_device_tokens.sql",
	"004_default_skill_memory.sql",
	"005_agent_to_agent_cross_chain_memory.sql",
	"006_live_agents_skill_memory.sql",
	"007_hide_agent_to_agent_from_user_chat.sql",
	"008_read_inbound_messages_skill_memory.sql",
	"009_artifact_metadata.sql",
	"010_artifact_usage_skill_memory.sql",
	"011_artifact_download_skill_memory.sql",
	"012_task_chains_v2.sql",
	"013_task_workflow_skill_memory.sql",
	"014_task_workflow_skill_comments.sql",
	"015_memory_target_scope.sql",
	"016_memory_workflow_skill_memory.sql",
	"017_chat_message_types.sql",
	"018_coordinator_member_backfill.sql",
	"019_current_task_and_priority.sql",
	"020_title_tracking.sql",
	"021_agent_instance_display_name.sql",
	"022_scheduled_prompts.sql",
	"023_actions.sql",
	"024_push_subscriptions.sql",
	"025_lookup_indexes.sql",
	"026_memory_scope_lists.sql",
	"027_default_coordinator_agent.sql",
	"028_memory_description_and_cleanup.sql",
	"029_search_fts_comments.sql",
	"030_search_fts_all.sql",
	"031_search_fts_messages.sql",
	"032_ai_native_templates.sql",
	"033_default_agents_and_conversation_project.sql",
	"034_cards.sql",
	"035_curator_template.sql",
	"036_action_targets.sql",
	"037_project_state.sql",
	"038_action_instance_strategy.sql",
	"039_shell_jobs.sql",
	"040_artifact_list_indexes.sql",
	"041_shell_sessions.sql",
	"042_pinned_task_chains.sql",
	"043_experiments.sql",
	"043_task_chain_directories.sql",
	"044_issues.sql",
	"044_lsp_servers.sql",
	"045_lsp_server_patterns.sql",
	"046_task_chain_fleets.sql",
	"048_task_subscriptions.sql",
	"048_shell_sessions_kind_and_key.sql",
	"049_shell_sessions_background_and_conversation.sql",
	"050_shell_sessions_kill_intent.sql",
	"051_shell_sessions_run_seq.sql",
	"052_drop_shell_jobs.sql",
	"053_bridge_version_and_updates.sql",
	"054_bridge_telemetry.sql",
	"055_memory_action_expiry.sql",
	"056_bridge_vault_status.sql",
	"057_bridge_tokens.sql",
	"058_provider_catalog.sql",
	"059_bridge_provider_state.sql",
	"060_explicit_provider_models.sql",
	"061_codex_launch_recipe.sql",
	"062_claude_startup_detection.sql",
	"063_claude_login_method_detection.sql",
	"064_codex_trust_detection.sql",
	"065_antigravity_launch_recipe.sql",
	"066_antigravity_trust_detection.sql",
	"067_codex_sandbox_and_models.sql",
	"068_repair_provider_catalog_etag.sql",
	"069_account_billing.sql",
	"070_free_one_bridge.sql",
	"071_codex_folder_access_trust.sql",
	"072_bridge_update_progress.sql",
	"072_instance_reconfiguration.sql",
	"073_claude_current_models.sql",
	"074_reconfiguration_recovery_stop.sql",
	"075_conversation_launch_preferences.sql",
	"076_fleet_bridge_models.sql",
	"077_soloist_agent.sql",
	"078_drop_stale_builtin_template_rows.sql",
	"079_repair_provider_catalog_etag.sql",
	"080_copilot_launch_recipe.sql",
	"081_antigravity_models.sql",
	"082_pi_provider.sql",
	"083_task_chain_search_feed.sql",
	"084_bridge_log_events.sql",
	"085_agent_instance_last_error.sql",
	"086_claude_bypass_permissions_detection.sql",
	"087_attention_cards.sql",
	"088_bridge_enrollment_pending.sql",
	"089_memory_proposer.sql",
	"090_task_v2.sql",
	"091_agent_instance_stopped_by.sql",
	"092_vault_device_directory.sql",
	"093_vault_signed_log.sql",
	"094_vault_hub_blind_pairing.sql",
	"095_vault_pairing_stretch.sql",
	"096_drop_password_vault.sql",
	"097_workflow_runs.sql",
	"098_mixed_work_graph.sql",
	"099_mixed_work_execution.sql",
	"100_vault_pair_hub_origin.sql",
	"101_codex_gpt6_models.sql",
	"102_drop_bridge_enrollments.sql",
	"103_plan_enforcement.sql",
	"106_agent_permission_mode.sql",
}

// stop_before is a TEST SEAM: when non-empty, the apply loop stops in front of
// that migration and the post-loop upgrade_* twins are skipped, which is how a
// migration test builds the exact pre-migration schema (e.g. the legacy task
// columns) before seeding fixture rows and running the real thing. Production
// callers never set it.
run_migrations :: proc(
	conn: ^Conn,
	migrations_dir := "src/hub/repository/sqlite/migrations",
	stop_before := "",
) -> (
	bool,
	domain.Domain_Error,
) {
	if conn == nil || conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "database connection is not open")
	}
	for name in migration_order {
		if stop_before != "" && name == stop_before do return true, domain.Domain_Error{}
		if name == "016_memory_workflow_skill_memory.sql" {
			if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
		}
		if migration_applied(conn, name) do continue
		if name == "003_device_tokens.sql" &&
		   table_column_exists(conn, "user_api_tokens", "created_from") &&
		   table_column_exists(conn, "user_api_tokens", "device_label") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "017_chat_message_types.sql" &&
		   table_column_exists(conn, "chat_messages", "message_type") &&
		   table_column_exists(conn, "chat_messages", "message_status") &&
		   table_column_exists(conn, "chat_messages", "metadata_json") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "019_current_task_and_priority.sql" &&
		   table_column_exists(conn, "agent_instances", "current_task_id") &&
		   table_column_exists(conn, "agent_instances", "current_task_role") &&
		   table_column_exists(conn, "tasks", "priority") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "020_title_tracking.sql" &&
		   table_column_exists(conn, "chat_conversations", "title_source") &&
		   table_column_exists(conn, "task_chains", "title_source") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "021_agent_instance_display_name.sql" &&
		   table_column_exists(conn, "agent_instances", "display_name") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "022_scheduled_prompts.sql" &&
		   table_column_exists(conn, "scheduled_prompts", "id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "023_actions.sql" && table_column_exists(conn, "actions", "cron_expr") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "024_push_subscriptions.sql" &&
		   table_column_exists(conn, "push_subscriptions", "endpoint") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "026_memory_scope_lists.sql" &&
		   table_column_exists(conn, "memories", "agent_ids") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "028_memory_description_and_cleanup.sql" &&
		   table_column_exists(conn, "memories", "description") {
			mark_migration_applied(conn, name)
			continue
		}
		// FTS5 migrations are skipped (marked applied) when FTS5 is unavailable or the
		// vtable already exists, so the append-only ledger stays consistent and
		// non-FTS builds boot on the indexed-LIKE fallback.
		if name == "029_search_fts_comments.sql" &&
		   (!fts5_available(conn) || sqlite_object_exists(conn, "task_comments_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "030_search_fts_all.sql" &&
		   (!fts5_available(conn) || sqlite_object_exists(conn, "memories_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "031_search_fts_messages.sql" &&
		   (!fts5_available(conn) || sqlite_object_exists(conn, "chat_messages_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "034_cards.sql" && table_column_exists(conn, "cards", "card_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "036_action_targets.sql" &&
		   table_column_exists(conn, "actions", "target_agent_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "037_project_state.sql" && table_column_exists(conn, "projects", "state") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "038_action_instance_strategy.sql" &&
		   table_column_exists(conn, "actions", "instance_strategy") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "039_shell_jobs.sql" && table_column_exists(conn, "shell_jobs", "exec_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "040_artifact_list_indexes.sql" &&
		   sqlite_object_exists(conn, "idx_artifacts_owner_created") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "041_shell_sessions.sql" &&
		   table_column_exists(conn, "shell_sessions", "session_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "042_pinned_task_chains.sql" &&
		   table_column_exists(conn, "task_chains", "is_pinned") &&
		   table_column_exists(conn, "task_chains", "pinned_at") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "043_experiments.sql" && sqlite_object_exists(conn, "experiments") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "044_lsp_servers.sql" && sqlite_object_exists(conn, "lsp_server_configs") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "043_task_chain_directories.sql" &&
		   sqlite_object_exists(conn, "task_chain_directories") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "044_issues.sql" &&
		   sqlite_object_exists(conn, "issues") &&
		   sqlite_object_exists(conn, "issue_comments") &&
		   sqlite_object_exists(conn, "issue_votes") {
			mark_migration_applied(conn, name)
			continue
		}
		if (name == "045_lsp_server_patterns.sql" || name == "046_lsp_server_patterns.sql") &&
		   table_column_exists(conn, "lsp_server_configs", "dir_pattern") {
			mark_migration_applied(conn, name)
			continue
		}
		if (name == "046_task_chain_fleets.sql" || name == "044_task_chain_fleets.sql") &&
		   sqlite_object_exists(conn, "task_chain_fleets") {
			mark_migration_applied(conn, name)
			continue
		}
		// Skip-guard keyed on a NEW index rather than on a column: 048 changes the
		// primary key and the kind vocabulary without adding or removing a column, so
		// table_column_exists cannot tell a migrated table from an unmigrated one.
		//
		// KEYED ON THE LAST OBJECT 048 CREATES, which is shell_sessions_owner_session
		// (048 line 83), NOT the earlier shell_sessions_agent (line 70). run_migrations
		// is not transactional -- there is no BEGIN/COMMIT around the apply loop -- so a
		// failure part-way through 048 leaves whatever it had already created in place.
		// Guarding on an EARLY object would then mark 048 applied while the UNIQUE index
		// shell_sessions_owner_session was missing, and that index is the constraint that
		// makes the owner-scoped by-session-id read single-row by construction rather than
		// by LIMIT 1 choosing arbitrarily between duplicates. Keying on the last object
		// means a partial apply cannot look complete. Same reasoning, same shape, as 050's
		// guard below. sqlite_object_exists queries sqlite_master by name with no type
		// filter, so it matches an index exactly as it matches a table.
		//
		// This is robustness against a FUTURE partial failure, not a live bug: no
		// reachable database today has 048 half-applied.
		if name == "048_shell_sessions_kind_and_key.sql" &&
		   sqlite_object_exists(conn, "shell_sessions_owner_session") {
			mark_migration_applied(conn, name)
			continue
		}
		// 049 only ADDS columns, so the column itself is the honest skip-guard here
		// (unlike 048, which changes the key without changing the column set).
		// ALTER TABLE ADD COLUMN is not idempotent in SQLite -- re-running it is a
		// hard "duplicate column name" error, which would abort startup migrations
		// on any database that reached 049 through the pre-ledger recovery path.
		if name == "049_shell_sessions_background_and_conversation.sql" &&
		   table_column_exists(conn, "shell_sessions", "background") {
			mark_migration_applied(conn, name)
			continue
		}
		// 050 is ALTER TABLE ADD COLUMN too, so it needs a skip guard for the same
		// reason 049 does: SQLite has no IF NOT EXISTS for ADD COLUMN, and a re-run is
		// a hard "duplicate column name" that would abort startup migrations on any
		// database that reached 050 through the pre-ledger recovery path.
		//
		// KEYED ON THE LAST OBJECT 050 CREATES (the index), NOT THE FIRST (the column)
		// — REQ-SHELL-13 N1. 050 creates two objects and run_migrations is not
		// transactional, so a pass that added the column and died before the index
		// leaves a database a column-keyed guard would declare finished, with the replay
		// lookup's index permanently missing. Keying on the LAST object makes the guard
		// unfakeable by a partial apply: it is satisfied only once every object exists.
		//
		// THE PARTIAL APPLY THEN NEEDS ITS OWN BRANCH, and this is the part keying on
		// the last object alone would get wrong. The self-heal twins all run AFTER this
		// loop, so falling through on a half-applied 050 would re-exec the migration
		// file, whose ALTER TABLE ADD COLUMN is a hard "duplicate column name" against
		// the column that is already there — aborting startup on exactly the state the
		// guard exists to catch, with the twin that could have repaired it never
		// reached. So the half-applied case is repaired HERE, by the same per-object
		// twin, before the ledger is marked.
		//
		// Three states, one for each thing that can be true:
		//   both objects  -> nothing to do; mark and skip.
		//   column only   -> partial apply; repair the missing half via the twin.
		//   neither       -> fall through and run the migration file normally.
		if name == "050_shell_sessions_kill_intent.sql" {
			if sqlite_object_exists(conn, "shell_sessions_pending_kill") {
				mark_migration_applied(conn, name)
				continue
			}
			if table_column_exists(conn, "shell_sessions", "kill_requested_at") {
				if !upgrade_shell_sessions_kill_intent_schema(conn) {
					return false, domain.domain_error(
						.Internal_Error,
						"failed to repair a half-applied 050_shell_sessions_kill_intent",
					)
				}
				mark_migration_applied(conn, name)
				continue
			}
		}
		// 051 adds exactly ONE object — the run_seq column — so unlike 050 there is no
		// "last object" distinct from the first and no partial-apply state to repair:
		// the column either exists or the migration never ran. The guard is therefore
		// the column itself, as it is for 049.
		//
		// It still NEEDS a guard for the same reason 049 and 050 do: SQLite has no
		// IF NOT EXISTS for ADD COLUMN, so a re-run on a database that reached 051
		// through the pre-ledger recovery path is a hard "duplicate column name" that
		// would abort startup migrations.
		if name == "051_shell_sessions_run_seq.sql" &&
		   table_column_exists(conn, "shell_sessions", "run_seq") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "053_bridge_version_and_updates.sql" &&
		   table_column_exists(conn, "bridges", "version") &&
		   table_column_exists(conn, "bridges", "update_error") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "054_bridge_telemetry.sql" &&
		   table_column_exists(conn, "bridges", "telemetry_enabled") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "055_memory_action_expiry.sql" &&
		   table_column_exists(conn, "memories", "expires_at") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "056_bridge_vault_status.sql" &&
		   table_column_exists(conn, "bridges", "vault_status") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "089_memory_proposer.sql" &&
		   table_column_exists(conn, "memories", "proposed_in_chain_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "088_bridge_enrollment_pending.sql" &&
		   table_column_exists(conn, "bridges", "enrollment_pending_until") {
			mark_migration_applied(conn, name)
			continue
		}
		// 057 creates a TABLE plus two indexes, all with IF NOT EXISTS, so unlike the
		// ADD COLUMN migrations above it is already idempotent and strictly does not
		// need a guard. It gets one anyway, for the same reason 053-056 have one: a
		// database that reached this schema through the pre-ledger recovery path has
		// the objects but not the ledger row, and marking it applied without
		// re-executing keeps startup migrations off a table that is now on the
		// authentication path. Keyed on the LAST object created by the file (the
		// family index), not the first, so a half-applied file is re-run rather than
		// marked done — the same reasoning as 050's twin.
		if name == "057_bridge_tokens.sql" && sqlite_object_exists(conn, "bridge_tokens_family") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "058_provider_catalog.sql" && sqlite_object_exists(conn, "provider_icons") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "059_bridge_provider_state.sql" &&
		   sqlite_object_exists(conn, "bridge_provider_settings") {
			mark_migration_applied(conn, name)
			continue
		}
		// 090 runs inside its own BEGIN/COMMIT, so it is either fully applied or
		// absent; the guard only has to recognise a database that reached the schema
		// through a pre-ledger path. Keyed on the LAST object the file creates
		// (idx_tasks_chain_state) so nothing short of a complete apply reads as done.
		if name == "090_task_v2.sql" &&
		   sqlite_object_exists(conn, "idx_tasks_chain_state") {
			mark_migration_applied(conn, name)
			continue
		}
		// A database that ran this file under its pre-merge name (088) has the
		// column but not the ledger row for the new name.
		if name == "091_agent_instance_stopped_by.sql" &&
		   table_column_exists(conn, "agent_instances", "stopped_by") {
			mark_migration_applied(conn, name)
			continue
		}
		// Keyed on the LAST object 092 creates.
		if name == "092_vault_device_directory.sql" &&
		   sqlite_object_exists(conn, "vault_directory_resets") {
			mark_migration_applied(conn, name)
			continue
		}
		// 097 commits atomically before its ledger row is written. If the
		// process exits between those writes, its LAST trigger proves that
		// the whole schema exists; preserve any runs already written there.
		if name == "097_workflow_runs.sql" &&
		   sqlite_object_exists(conn, "workflow_runs_no_delete") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "098_mixed_work_graph.sql" &&
		   sqlite_object_exists(conn, "work_scope_decisions_no_delete") {
			mark_migration_applied(conn, name)
			continue
		}
		// 103 commits atomically before its ledger row. Its final column proves
		// completion if the process exits between those writes.
		if name == "103_plan_enforcement.sql" &&
		   table_column_exists(conn, "bridges", "plan_disabled_at") &&
		   table_column_exists(conn, "account_entitlements", "override_shells_enabled") {
			mark_migration_applied(conn, name)
			continue
		}
		// 106 is a single ALTER; a database that already has the column needs nothing.
		if name == "106_agent_permission_mode.sql" && table_column_exists(conn, "agents", "permission_mode") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "099_mixed_work_execution.sql" && sqlite_object_exists(conn, "mixed_work_engine_epoch") {
			mark_migration_applied(conn, name)
			continue
		}
		// 095 drops the vault tables on a fresh database (092 is re-run after the loop
		// with the column), and a database that already has the column needs nothing.
		if name == "100_vault_pair_hub_origin.sql" &&
		   (!sqlite_object_exists(conn, "vault_devices") || table_column_exists(conn, "vault_devices", "pair_hub_origin")) {
			mark_migration_applied(conn, name)
			continue
		}
		sql := migration_sql(name, migrations_dir)
		if sql == "" {
			return false, domain.domain_error(
				.Internal_Error,
				fmt.tprintf("missing migration %s", name),
			)
		}
		if !exec(conn, sql) {
			delete(sql)
			return false, domain.domain_error(
				.Internal_Error,
				fmt.tprintf("migration failed: %s", name),
			)
		}
		mark_migration_applied(conn, name)
		delete(sql)
	}
	if !upgrade_user_api_tokens_schema(conn) do return false, domain.domain_error(.Internal_Error, "user_api_tokens schema upgrade failed")
	if !upgrade_task_comments_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_comments schema upgrade failed")
	if !upgrade_task_chains_v2_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chains_v2 schema upgrade failed")
	if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
	if !upgrade_memory_scope_lists_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory scope lists schema upgrade failed")
	if !upgrade_chat_message_types_schema(conn) do return false, domain.domain_error(.Internal_Error, "chat message type schema upgrade failed")
	if !upgrade_current_task_and_priority_schema(conn) do return false, domain.domain_error(.Internal_Error, "current task + priority schema upgrade failed")
	if !upgrade_title_tracking_schema(conn) do return false, domain.domain_error(.Internal_Error, "title tracking schema upgrade failed")
	if !upgrade_agent_instance_display_name_schema(conn) do return false, domain.domain_error(.Internal_Error, "agent instance display_name schema upgrade failed")
	if !upgrade_scheduled_prompts_schema(conn) do return false, domain.domain_error(.Internal_Error, "scheduled prompts schema upgrade failed")
	if !upgrade_actions_schema(conn) do return false, domain.domain_error(.Internal_Error, "actions schema upgrade failed")
	if !upgrade_push_subscriptions_schema(conn) do return false, domain.domain_error(.Internal_Error, "push subscriptions schema upgrade failed")
	if !upgrade_memory_description_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory description schema upgrade failed")
	if !upgrade_cards_schema(conn) do return false, domain.domain_error(.Internal_Error, "cards schema upgrade failed")
	if !upgrade_projects_state_schema(conn) do return false, domain.domain_error(.Internal_Error, "projects state schema upgrade failed")
	if !upgrade_artifact_indexes_schema(conn) do return false, domain.domain_error(.Internal_Error, "artifact indexes schema upgrade failed")
	if !upgrade_pinned_task_chains_schema(conn) do return false, domain.domain_error(.Internal_Error, "pinned task chains schema upgrade failed")
	if !upgrade_task_chain_directories_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chain_directories schema upgrade failed")
	if !upgrade_task_chain_fleets_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chain_fleets schema upgrade failed")
	if !upgrade_task_bridge_schema(conn) do return false, domain.domain_error(.Internal_Error, "task bridge_id schema upgrade failed")
	if !upgrade_shell_sessions_kind_and_key_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions kind + key schema upgrade failed")
	if !upgrade_shell_sessions_background_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions background + conversation schema upgrade failed")
	if !upgrade_shell_sessions_kill_intent_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions kill intent schema upgrade failed")
	if !upgrade_shell_sessions_run_seq_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions run_seq schema upgrade failed")
	if !upgrade_bridge_version_and_updates_schema(conn) do return false, domain.domain_error(.Internal_Error, "bridge version and updates schema upgrade failed")
	if !upgrade_bridge_update_progress_schema(conn) do return false, domain.domain_error(.Internal_Error, "bridge update progress schema upgrade failed")
	if !upgrade_memory_action_expiry_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory action expiry schema upgrade failed")
	if !upgrade_task_v2_schema(conn) do return false, domain.domain_error(.Internal_Error, "task v2 schema upgrade failed")
	if !upgrade_vault_directory_schema(conn) do return false, domain.domain_error(.Internal_Error, "vault directory schema upgrade failed")
	return true, domain.Domain_Error{}
}

migration_sql :: proc(name, migrations_dir: string) -> string {
	if migrations_dir != "" {
		path := strings.concatenate({migrations_dir, "/", name}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.allocator)
		if err == nil {
			return string(data)
		}
	}
	if name == "001_foundation.sql" do return strings.clone(MIGRATION_001_FOUNDATION)
	if name == "002_owner_scoped_core.sql" do return strings.clone(MIGRATION_002_OWNER_SCOPED_CORE)
	if name == "003_device_tokens.sql" do return strings.clone(MIGRATION_003_DEVICE_TOKENS)
	if name == "004_default_skill_memory.sql" do return strings.clone(MIGRATION_004_DEFAULT_SKILL_MEMORY)
	if name == "005_agent_to_agent_cross_chain_memory.sql" do return strings.clone(MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY)
	if name == "006_live_agents_skill_memory.sql" do return strings.clone(MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY)
	if name == "007_hide_agent_to_agent_from_user_chat.sql" do return strings.clone(MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT)
	if name == "008_read_inbound_messages_skill_memory.sql" do return strings.clone(MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY)
	if name == "009_artifact_metadata.sql" do return strings.clone(MIGRATION_009_ARTIFACT_METADATA)
	if name == "010_artifact_usage_skill_memory.sql" do return strings.clone(MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY)
	if name == "011_artifact_download_skill_memory.sql" do return strings.clone(MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY)
	if name == "012_task_chains_v2.sql" do return strings.clone(MIGRATION_012_TASK_CHAINS_V2)
	if name == "013_task_workflow_skill_memory.sql" do return strings.clone(MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY)
	if name == "014_task_workflow_skill_comments.sql" do return strings.clone(MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS)
	if name == "015_memory_target_scope.sql" do return strings.clone(MIGRATION_015_MEMORY_TARGET_SCOPE)
	if name == "016_memory_workflow_skill_memory.sql" do return strings.clone(MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY)
	if name == "017_chat_message_types.sql" do return strings.clone(MIGRATION_017_CHAT_MESSAGE_TYPES)
	if name == "018_coordinator_member_backfill.sql" do return strings.clone(MIGRATION_018_COORDINATOR_MEMBER_BACKFILL)
	if name == "019_current_task_and_priority.sql" do return strings.clone(MIGRATION_019_CURRENT_TASK_AND_PRIORITY)
	if name == "020_title_tracking.sql" do return strings.clone(MIGRATION_020_TITLE_TRACKING)
	if name == "021_agent_instance_display_name.sql" do return strings.clone(MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME)
	if name == "022_scheduled_prompts.sql" do return strings.clone(MIGRATION_022_SCHEDULED_PROMPTS)
	if name == "023_actions.sql" do return strings.clone(MIGRATION_023_ACTIONS)
	if name == "024_push_subscriptions.sql" do return strings.clone(MIGRATION_024_PUSH_SUBSCRIPTIONS)
	if name == "025_lookup_indexes.sql" do return strings.clone(MIGRATION_025_LOOKUP_INDEXES)
	if name == "026_memory_scope_lists.sql" do return strings.clone(MIGRATION_026_MEMORY_SCOPE_LISTS)
	if name == "027_default_coordinator_agent.sql" do return strings.clone(MIGRATION_027_DEFAULT_COORDINATOR_AGENT)
	if name == "028_memory_description_and_cleanup.sql" do return strings.clone(MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP)
	if name == "029_search_fts_comments.sql" do return strings.clone(MIGRATION_029_SEARCH_FTS_COMMENTS)
	if name == "030_search_fts_all.sql" do return strings.clone(MIGRATION_030_SEARCH_FTS_ALL)
	if name == "031_search_fts_messages.sql" do return strings.clone(MIGRATION_031_SEARCH_FTS_MESSAGES)
	if name == "032_ai_native_templates.sql" do return strings.clone(MIGRATION_032_AI_NATIVE_TEMPLATES)
	if name == "033_default_agents_and_conversation_project.sql" do return strings.clone(MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT)
	if name == "034_cards.sql" do return strings.clone(MIGRATION_034_CARDS)
	if name == "035_curator_template.sql" do return strings.clone(MIGRATION_035_CURATOR_TEMPLATE)
	if name == "036_action_targets.sql" do return strings.clone(MIGRATION_036_ACTION_TARGETS)
	if name == "037_project_state.sql" do return strings.clone(MIGRATION_037_PROJECT_STATE)
	if name == "038_action_instance_strategy.sql" do return strings.clone(MIGRATION_038_ACTION_INSTANCE_STRATEGY)
	if name == "039_shell_jobs.sql" do return strings.clone(MIGRATION_039_SHELL_JOBS)
	if name == "040_artifact_list_indexes.sql" do return strings.clone(MIGRATION_040_ARTIFACT_LIST_INDEXES)
	if name == "041_shell_sessions.sql" do return strings.clone(MIGRATION_041_SHELL_SESSIONS)
	if name == "042_pinned_task_chains.sql" do return strings.clone(MIGRATION_042_PINNED_TASK_CHAINS)
	if name == "043_experiments.sql" do return strings.clone(MIGRATION_043_EXPERIMENTS)
	if name == "043_task_chain_directories.sql" do return strings.clone(MIGRATION_043_TASK_CHAIN_DIRECTORIES)
	if name == "044_issues.sql" do return strings.clone(MIGRATION_044_ISSUES)
	if name == "044_lsp_servers.sql" do return strings.clone(MIGRATION_044_LSP_SERVERS)
	if name == "045_lsp_server_patterns.sql" || name == "046_lsp_server_patterns.sql" do return strings.clone(MIGRATION_045_LSP_SERVER_PATTERNS)
	if name == "046_task_chain_fleets.sql" || name == "044_task_chain_fleets.sql" do return strings.clone(MIGRATION_046_TASK_CHAIN_FLEETS)
	if name == "048_task_subscriptions.sql" || name == "049_task_subscriptions.sql" do return strings.clone(MIGRATION_048_TASK_SUBSCRIPTIONS)
	if name == "048_shell_sessions_kind_and_key.sql" do return strings.clone(MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY)
	if name == "049_shell_sessions_background_and_conversation.sql" do return strings.clone(MIGRATION_049_SHELL_SESSIONS_BACKGROUND_AND_CONVERSATION)
	if name == "050_shell_sessions_kill_intent.sql" do return strings.clone(MIGRATION_050_SHELL_SESSIONS_KILL_INTENT)
	if name == "051_shell_sessions_run_seq.sql" do return strings.clone(MIGRATION_051_SHELL_SESSIONS_RUN_SEQ)
	if name == "052_drop_shell_jobs.sql" do return strings.clone(MIGRATION_052_DROP_SHELL_JOBS)
	if name == "053_bridge_version_and_updates.sql" do return strings.clone(MIGRATION_053_BRIDGE_VERSION_AND_UPDATES)
	if name == "054_bridge_telemetry.sql" do return strings.clone(MIGRATION_054_BRIDGE_TELEMETRY)
	if name == "055_memory_action_expiry.sql" do return strings.clone(MIGRATION_055_MEMORY_ACTION_EXPIRY)
	if name == "056_bridge_vault_status.sql" do return strings.clone(MIGRATION_056_BRIDGE_VAULT_STATUS)
	if name == "057_bridge_tokens.sql" do return strings.clone(MIGRATION_057_BRIDGE_TOKENS)
	if name == "058_provider_catalog.sql" do return strings.clone(MIGRATION_058_PROVIDER_CATALOG)
	if name == "059_bridge_provider_state.sql" do return strings.clone(MIGRATION_059_BRIDGE_PROVIDER_STATE)
	if name == "060_explicit_provider_models.sql" do return strings.clone(MIGRATION_060_EXPLICIT_PROVIDER_MODELS)
	if name == "061_codex_launch_recipe.sql" do return strings.clone(MIGRATION_061_CODEX_LAUNCH_RECIPE)
	if name == "062_claude_startup_detection.sql" do return strings.clone(MIGRATION_062_CLAUDE_STARTUP_DETECTION)
	if name == "063_claude_login_method_detection.sql" do return strings.clone(MIGRATION_063_CLAUDE_LOGIN_METHOD_DETECTION)
	if name == "064_codex_trust_detection.sql" do return strings.clone(MIGRATION_064_CODEX_TRUST_DETECTION)
	if name == "065_antigravity_launch_recipe.sql" do return strings.clone(MIGRATION_065_ANTIGRAVITY_LAUNCH_RECIPE)
	if name == "066_antigravity_trust_detection.sql" do return strings.clone(MIGRATION_066_ANTIGRAVITY_TRUST_DETECTION)
	if name == "067_codex_sandbox_and_models.sql" do return strings.clone(MIGRATION_067_CODEX_SANDBOX_AND_MODELS)
	if name == "070_free_one_bridge.sql" do return strings.clone(MIGRATION_070_FREE_ONE_BRIDGE)
	if name == "082_pi_provider.sql" do return strings.clone(MIGRATION_082_PI_PROVIDER)
	if name == "083_task_chain_search_feed.sql" do return strings.clone(MIGRATION_083_TASK_CHAIN_SEARCH_FEED)
	if name == "084_bridge_log_events.sql" do return strings.clone(MIGRATION_084_BRIDGE_LOG_EVENTS)
	if name == "085_agent_instance_last_error.sql" do return strings.clone(MIGRATION_085_AGENT_INSTANCE_LAST_ERROR)
	if name == "086_claude_bypass_permissions_detection.sql" do return strings.clone(MIGRATION_086_CLAUDE_BYPASS_PERMISSIONS_DETECTION)
	if name == "087_attention_cards.sql" do return strings.clone(MIGRATION_087_ATTENTION_CARDS)
	if name == "088_bridge_enrollment_pending.sql" do return strings.clone(MIGRATION_088_BRIDGE_ENROLLMENT_PENDING)
	if name == "089_memory_proposer.sql" do return strings.clone(MIGRATION_089_MEMORY_PROPOSER)
	if name == "090_task_v2.sql" do return strings.clone(MIGRATION_090_TASK_V2)
	if name == "091_agent_instance_stopped_by.sql" do return strings.clone(MIGRATION_091_AGENT_INSTANCE_STOPPED_BY)
	if name == "092_vault_device_directory.sql" do return strings.clone(MIGRATION_092_VAULT_DEVICE_DIRECTORY)
	if name == "093_vault_signed_log.sql" do return strings.clone(MIGRATION_093_VAULT_SIGNED_LOG)
	if name == "094_vault_hub_blind_pairing.sql" do return strings.clone(MIGRATION_094_VAULT_HUB_BLIND_PAIRING)
	if name == "095_vault_pairing_stretch.sql" do return strings.clone(MIGRATION_095_VAULT_PAIRING_STRETCH)
	if name == "096_drop_password_vault.sql" do return strings.clone(MIGRATION_096_DROP_PASSWORD_VAULT)
	if name == "097_workflow_runs.sql" do return strings.clone(MIGRATION_097_WORKFLOW_RUNS)
	if name == "098_mixed_work_graph.sql" do return strings.clone(MIGRATION_098_MIXED_WORK_GRAPH)
	if name == "099_mixed_work_execution.sql" do return strings.clone(MIGRATION_099_MIXED_WORK_EXECUTION)
	if name == "102_drop_bridge_enrollments.sql" do return strings.clone(MIGRATION_102_DROP_BRIDGE_ENROLLMENTS)
	if name == "103_plan_enforcement.sql" do return strings.clone(MIGRATION_103_PLAN_ENFORCEMENT)
	if name == "106_agent_permission_mode.sql" do return strings.clone(MIGRATION_106_AGENT_PERMISSION_MODE)
	if name == "100_vault_pair_hub_origin.sql" do return strings.clone(MIGRATION_100_VAULT_PAIR_HUB_ORIGIN)
	if name == "101_codex_gpt6_models.sql" do return strings.clone(MIGRATION_101_CODEX_GPT6_MODELS)
	if name == "081_antigravity_models.sql" do return strings.clone(MIGRATION_081_ANTIGRAVITY_MODELS)
	if name == "080_copilot_launch_recipe.sql" do return strings.clone(MIGRATION_080_COPILOT_LAUNCH_RECIPE)
	if name == "079_repair_provider_catalog_etag.sql" do return strings.clone(MIGRATION_079_REPAIR_PROVIDER_CATALOG_ETAG)
	if name == "078_drop_stale_builtin_template_rows.sql" do return strings.clone(MIGRATION_078_DROP_STALE_BUILTIN_TEMPLATE_ROWS)
	if name == "077_soloist_agent.sql" do return strings.clone(MIGRATION_077_SOLOIST_AGENT)
	if name == "076_fleet_bridge_models.sql" do return strings.clone(MIGRATION_076_FLEET_BRIDGE_MODELS)
	if name == "075_conversation_launch_preferences.sql" do return strings.clone(MIGRATION_075_CONVERSATION_LAUNCH_PREFERENCES)
	if name == "074_reconfiguration_recovery_stop.sql" do return strings.clone(MIGRATION_074_RECONFIGURATION_RECOVERY_STOP)
	if name == "073_claude_current_models.sql" do return strings.clone(MIGRATION_073_CLAUDE_CURRENT_MODELS)
	if name == "072_instance_reconfiguration.sql" do return strings.clone(MIGRATION_072_INSTANCE_RECONFIGURATION)
	if name == "071_codex_folder_access_trust.sql" do return strings.clone(MIGRATION_071_CODEX_FOLDER_ACCESS_TRUST)
	if name == "072_bridge_update_progress.sql" do return strings.clone(MIGRATION_072_BRIDGE_UPDATE_PROGRESS)
	if name == "069_account_billing.sql" do return strings.clone(MIGRATION_069_ACCOUNT_BILLING)
	if name == "068_repair_provider_catalog_etag.sql" do return strings.clone(MIGRATION_068_REPAIR_PROVIDER_CATALOG_ETAG)
	return ""
}

migration_applied :: proc(conn: ^Conn, version: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(
		"SELECT 1 FROM schema_migrations WHERE version='%s' LIMIT 1;",
		escape_sql_literal(version),
	)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) == SQLITE_ROW do return true
	if version == "046_task_chain_fleets.sql" {
		return migration_applied(conn, "044_task_chain_fleets.sql")
	}
	if version == "048_task_subscriptions.sql" || version == "049_task_subscriptions.sql" {
		return sqlite_object_exists(conn, "task_subscriptions")
	}
	if version == "048_shell_sessions_kind_and_key.sql" {
		// The LAST object 048 creates, matching its skip guard above — a partial apply
		// that stopped before the UNIQUE index must not read back as applied.
		return sqlite_object_exists(conn, "shell_sessions_owner_session")
	}
	if version == "049_shell_sessions_background_and_conversation.sql" {
		return table_column_exists(conn, "shell_sessions", "background")
	}
	if version == "050_shell_sessions_kill_intent.sql" {
		// The LAST object 050 creates, matching its skip guard — a partial apply that
		// stopped after the column must not read back as applied.
		return sqlite_object_exists(conn, "shell_sessions_pending_kill")
	}
	if version == "051_shell_sessions_run_seq.sql" {
		// 051's only object, matching its skip guard. Single-object, so unlike 050
		// there is no partial apply this could read back as applied.
		return table_column_exists(conn, "shell_sessions", "run_seq")
	}
	if version == "055_memory_action_expiry.sql" {
		return table_column_exists(conn, "memories", "expires_at")
	}
	return false
}

mark_migration_applied :: proc(conn: ^Conn, version: string) {
	query := fmt.tprintf(
		"INSERT OR IGNORE INTO schema_migrations (version) VALUES ('%s');",
		escape_sql_literal(version),
	)
	exec(conn, query)
}

upgrade_user_api_tokens_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "user_api_tokens", "label") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN label TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "last_used_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN last_used_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "expires_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "revoked_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN revoked_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "created_from") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN created_from TEXT NOT NULL DEFAULT 'operator';") do return false
	if !table_column_exists(conn, "user_api_tokens", "device_label") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN device_label TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE UNIQUE INDEX IF NOT EXISTS idx_user_api_tokens_token_hash ON user_api_tokens(token_hash);") do return false
	return true
}

upgrade_task_comments_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_comments", "author_agent_instance_id") && !exec(conn, "ALTER TABLE task_comments ADD COLUMN author_agent_instance_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// fts5_available reports whether the linked SQLite was built with ENABLE_FTS5.
fts5_available :: proc(conn: ^Conn) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := "SELECT count(*) FROM pragma_compile_options WHERE compile_options = 'ENABLE_FTS5';"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return false
	return int_v(column_text_unowned(stmt, 0)) > 0
}

// sqlite_object_exists reports whether a table/vtable/trigger of the given name
// exists (sqlite_master lookup). Used to detect the FTS vtable idempotently.
sqlite_object_exists :: proc(conn: ^Conn, name: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(
		"SELECT 1 FROM sqlite_master WHERE name='%s' LIMIT 1;",
		escape_sql_literal(name),
	)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}

table_column_exists :: proc(conn: ^Conn, table_name, column_name: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("PRAGMA table_info(%s);", table_name)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		if column_text_unowned(stmt, 1) == column_name do return true
	}
	return false
}

escape_sql_literal :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	return strings.to_string(builder)
}

upgrade_task_chains_v2_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_chains", "description") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "description") && !exec(conn, "ALTER TABLE tasks ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_memory_target_scope_schema :: proc(conn: ^Conn) -> bool {
	// Once migration 025 has converted the memories table to JSON-array list
	// columns (and dropped the scalar scope columns), the legacy scalar backfill
	// must be a no-op — otherwise it would re-create the dropped columns.
	if table_column_exists(conn, "memories", "agent_ids") do return true
	if !table_column_exists(conn, "memories", "project_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN project_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "memories", "template_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN template_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "memories", "bridge_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// upgrade_memory_scope_lists_schema is the idempotent end-of-run guard for
// migration 026. When an existing DB still has the scalar scope columns, it adds
// the list columns, backfills each from its scalar (empty -> '[]', else a
// single-element array), and drops the scalars. It is a no-op once agent_ids
// exists. Kept in sync with MIGRATION_026_MEMORY_SCOPE_LISTS.
upgrade_memory_scope_lists_schema :: proc(conn: ^Conn) -> bool {
	if table_column_exists(conn, "memories", "agent_ids") do return true
	if !exec(conn, "ALTER TABLE memories ADD COLUMN agent_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "ALTER TABLE memories ADD COLUMN project_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "ALTER TABLE memories ADD COLUMN template_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "ALTER TABLE memories ADD COLUMN bridge_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "UPDATE memories SET agent_ids = CASE WHEN agent_id = '' THEN '[]' ELSE '[\"' || agent_id || '\"]' END, project_ids = CASE WHEN project_id = '' THEN '[]' ELSE '[\"' || project_id || '\"]' END, template_ids = CASE WHEN template_id = '' THEN '[]' ELSE '[\"' || template_id || '\"]' END, bridge_ids = CASE WHEN bridge_id = '' THEN '[]' ELSE '[\"' || bridge_id || '\"]' END;") do return false
	if table_column_exists(conn, "memories", "agent_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN agent_id;") do return false
	if table_column_exists(conn, "memories", "project_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN project_id;") do return false
	if table_column_exists(conn, "memories", "template_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN template_id;") do return false
	if table_column_exists(conn, "memories", "bridge_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN bridge_id;") do return false
	return true
}

upgrade_chat_message_types_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "chat_messages", "message_type") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'text';") do return false
	if !table_column_exists(conn, "chat_messages", "message_status") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN message_status TEXT NOT NULL DEFAULT 'complete';") do return false
	if !table_column_exists(conn, "chat_messages", "metadata_json") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';") do return false
	return true
}

upgrade_current_task_and_priority_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "agent_instances", "current_task_id") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN current_task_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "agent_instances", "current_task_role") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN current_task_role TEXT NOT NULL DEFAULT 'none';") do return false
	if !table_column_exists(conn, "tasks", "priority") && !exec(conn, "ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'p2';") do return false
	return true
}

upgrade_title_tracking_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "chat_conversations", "last_activity_at") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chat_conversations", "last_title_nudge_at") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chat_conversations", "title_source") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';") do return false
	if !table_column_exists(conn, "task_chains", "last_activity_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "last_title_nudge_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "title_source") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';") do return false
	if !exec(conn, "CREATE TABLE IF NOT EXISTS agent_title_counters (agent_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, counter INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');") do return false
	return true
}

upgrade_agent_instance_display_name_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "agent_instances", "display_name") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN display_name TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_scheduled_prompts_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS scheduled_prompts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  target_run_at TEXT NOT NULL,
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scheduled_prompts_target ON scheduled_prompts(target_instance_id);`,
	)
}

upgrade_actions_schema :: proc(conn: ^Conn) -> bool {
	if !exec(
		conn,
		`CREATE TABLE IF NOT EXISTS actions (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  cron_expr TEXT NOT NULL DEFAULT '',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  blackout_dates TEXT NOT NULL DEFAULT '[]',
  active_from TEXT NOT NULL DEFAULT '',
  active_until TEXT NOT NULL DEFAULT '',
  target_run_at TEXT NOT NULL DEFAULT '',
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_actions_target ON actions(target_instance_id);
CREATE INDEX IF NOT EXISTS idx_actions_owner_run ON actions(owner_user_id, target_run_at);
CREATE INDEX IF NOT EXISTS idx_actions_due ON actions(target_run_at) WHERE state = 'active' AND in_flight = 0 AND deleted_at = '';
CREATE TRIGGER IF NOT EXISTS actions_owner_immutable BEFORE UPDATE OF owner_user_id ON actions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	) {
		return false
	}

	if !table_column_exists(conn, "actions", "cron_expr") && !exec(conn, "ALTER TABLE actions ADD COLUMN cron_expr TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "timezone") && !exec(conn, "ALTER TABLE actions ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';") do return false
	if !table_column_exists(conn, "actions", "blackout_dates") && !exec(conn, "ALTER TABLE actions ADD COLUMN blackout_dates TEXT NOT NULL DEFAULT '[]';") do return false
	if !table_column_exists(conn, "actions", "active_from") && !exec(conn, "ALTER TABLE actions ADD COLUMN active_from TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "active_until") && !exec(conn, "ALTER TABLE actions ADD COLUMN active_until TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_agent_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_agent_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_bridge_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_bridge_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_provider") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_provider TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_model") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_model TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_project_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_project_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "instance_strategy") && !exec(conn, "ALTER TABLE actions ADD COLUMN instance_strategy TEXT NOT NULL DEFAULT 'reuse';") do return false
	if !table_column_exists(conn, "actions", "last_spawned_instance_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN last_spawned_instance_id TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_actions_target_agent ON actions(target_agent_id);") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_actions_target_bridge ON actions(target_bridge_id);") do return false

	if table_column_exists(conn, "scheduled_prompts", "id") {
		exec(
			conn,
			`INSERT OR IGNORE INTO actions (
  id, owner_user_id, target_instance_id, prompt_text, target_run_at,
  interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
)
SELECT
  id, owner_user_id, target_instance_id, prompt_text, target_run_at,
  interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
FROM scheduled_prompts;`,
		)
	}
	return true
}

// upgrade_push_subscriptions_schema idempotently ensures the push_subscriptions
// table, its unique-endpoint index, and the owner-immutable trigger exist. Runs
// on every startup so a DB predating migration 024 self-heals.
upgrade_push_subscriptions_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS push_subscriptions (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_push_subscriptions_endpoint ON push_subscriptions(endpoint);
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_owner ON push_subscriptions(owner_user_id);
CREATE TRIGGER IF NOT EXISTS push_subscriptions_owner_immutable BEFORE UPDATE OF owner_user_id ON push_subscriptions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	)
}

upgrade_memory_description_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "memories", "description") {
		if !exec(conn, "ALTER TABLE memories ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	}
	exec(
		conn,
		"DELETE FROM memories WHERE owner_user_id = 'system' AND (type = 'skill' OR memory_id LIKE 'mem_system_%');",
	)
	return true
}

// upgrade_cards_schema idempotently ensures the cards table, its indexes,
// and the owner-immutable trigger exist (REQ-CARD-1).
upgrade_cards_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  title TEXT NOT NULL,
  rationale TEXT NOT NULL DEFAULT '',
  scope TEXT NOT NULL DEFAULT 'project',
  provider TEXT NOT NULL DEFAULT '',
  confidence REAL NOT NULL DEFAULT 1.0,
  source_refs_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending',
  operations_json TEXT NOT NULL DEFAULT '[]',
  guard_json TEXT NOT NULL DEFAULT '{}',
  snooze_until TEXT NOT NULL DEFAULT '',
  ttl_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cards_owner ON cards(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_cards_project ON cards(project_id);
CREATE INDEX IF NOT EXISTS idx_cards_status ON cards(status);
CREATE INDEX IF NOT EXISTS idx_cards_owner_status ON cards(owner_user_id, status);
CREATE TRIGGER IF NOT EXISTS cards_owner_immutable BEFORE UPDATE OF owner_user_id ON cards BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	)
}

// upgrade_projects_state_schema idempotently ensures the projects `state` column
// exists (REQ-PROJ-ARCHIVE-1). Runs on every startup so a DB predating migration
// 037 self-heals, mirroring the agents `state` column.
upgrade_projects_state_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "projects", "state") && !exec(conn, "ALTER TABLE projects ADD COLUMN state TEXT NOT NULL DEFAULT 'active';") do return false
	return true
}

// upgrade_artifact_indexes_schema idempotently ensures the composite indexes
// for the artifacts table exist (REQ-ARTIFACT-DB-INDEXES).
upgrade_artifact_indexes_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE INDEX IF NOT EXISTS idx_artifacts_owner_project_created ON artifacts(owner_user_id, project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_instance_created ON artifacts(owner_user_id, agent_instance_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_chain_created ON artifacts(owner_user_id, chain_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_task_created ON artifacts(owner_user_id, task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_created ON artifacts(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_updated ON artifacts(owner_user_id, updated_at DESC);`,
	)
}

// upgrade_pinned_task_chains_schema idempotently ensures the task_chains
// is_pinned and pinned_at columns and index exist (REQ-PIN-DB-SCHEMA).
upgrade_pinned_task_chains_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_chains", "is_pinned") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "task_chains", "pinned_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN pinned_at TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_task_chains_owner_pinned ON task_chains(owner_user_id, is_pinned, pinned_at);") do return false
	return true
}

// upgrade_task_chain_directories_schema idempotently ensures the task_chain_directories
// table and index exist (REQ-BE-TASK-CHAIN-RELEVANT-DIRECTORIES).
upgrade_task_chain_directories_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS task_chain_directories (
  directory_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  path TEXT NOT NULL,
  bridge_id TEXT NOT NULL DEFAULT '',
  vcs_kind TEXT NOT NULL DEFAULT '',
  vcs_info_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (chain_id) REFERENCES task_chains(chain_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_chain_directories_chain_owner ON task_chain_directories(chain_id, owner_user_id);
CREATE TRIGGER IF NOT EXISTS task_chain_directories_owner_immutable BEFORE UPDATE OF owner_user_id ON task_chain_directories BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	)
}

// upgrade_task_chain_fleets_schema idempotently ensures the task_chain_fleets
// table, provider/model columns, and index exist (REQ-FLEET-SCHEMA-1,
// REQ-FLEET-PT-1).
upgrade_task_chain_fleets_schema :: proc(conn: ^Conn) -> bool {
	if !exec(
		conn,
		`CREATE TABLE IF NOT EXISTS task_chain_fleets (
  task_chain_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  capacity INTEGER NOT NULL DEFAULT 1,
  min_warm INTEGER NOT NULL DEFAULT 0,
  idle_ttl_seconds INTEGER NOT NULL DEFAULT 600,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (task_chain_id, agent_id),
  FOREIGN KEY (task_chain_id) REFERENCES task_chains(chain_id) ON DELETE CASCADE
);`,
	) {
		return false
	}
	if !table_column_exists(conn, "task_chain_fleets", "provider") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN provider TEXT NOT NULL DEFAULT '';") do return false
	if table_column_exists(conn, "task_chain_fleets", "tier") &&
	   !table_column_exists(conn, "task_chain_fleets", "model") {
		if !exec(conn, "ALTER TABLE task_chain_fleets RENAME COLUMN tier TO model;") do return false
	}
	if !table_column_exists(conn, "task_chain_fleets", "model") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN model TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_task_chain_fleets_chain ON task_chain_fleets(task_chain_id);") do return false
	return true
}

// upgrade_task_bridge_schema idempotently adds tasks.bridge_id (REQ-TB-1): the
// per-task bridge pin deciding which bridge instantiates the task's agent-id
// actors. Empty default = inherit (resolved at promotion time); no backfill.
upgrade_task_bridge_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "tasks", "bridge_id") && !exec(conn, "ALTER TABLE tasks ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// upgrade_task_v2_schema is 087's twin: it idempotently guarantees every v2
// column exists (a database that reached 087 half-way), then DROPS the legacy
// task-status/actor-ref columns and the votes/subscriptions tables whose data
// 087 has already converted.
//
// THE DROPS ARE TOLERANT. SQLite's DROP COLUMN refuses when the column is
// referenced by an index, trigger or view; on this schema none of them is, but a
// refusal must leave the column in place and log rather than abort startup — the
// engine never reads those columns, so a lingering one is dead weight, not a
// correctness problem. DROP TABLE is unconditional (nothing references them).
upgrade_task_v2_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "tasks", "state") && !exec(conn, "ALTER TABLE tasks ADD COLUMN state TEXT NOT NULL DEFAULT 'backlog';") do return false
	if !table_column_exists(conn, "tasks", "kind") && !exec(conn, "ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task';") do return false
	if !table_column_exists(conn, "tasks", "attempt_no") && !exec(conn, "ALTER TABLE tasks ADD COLUMN attempt_no INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "tasks", "brief_json") && !exec(conn, "ALTER TABLE tasks ADD COLUMN brief_json TEXT NOT NULL DEFAULT '{}';") do return false
	if !table_column_exists(conn, "tasks", "blocked_on_json") && !exec(conn, "ALTER TABLE tasks ADD COLUMN blocked_on_json TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "requires_user_approval") && !exec(conn, "ALTER TABLE tasks ADD COLUMN requires_user_approval INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "tasks", "ready_since") && !exec(conn, "ALTER TABLE tasks ADD COLUMN ready_since TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "stage_key") && !exec(conn, "ALTER TABLE tasks ADD COLUMN stage_key TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "stage_index") && !exec(conn, "ALTER TABLE tasks ADD COLUMN stage_index INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "tasks", "generated_by_json") && !exec(conn, "ALTER TABLE tasks ADD COLUMN generated_by_json TEXT NOT NULL DEFAULT '';") do return false
	if !sqlite_object_exists(conn, "mixed_work_engine_epoch") && !table_column_exists(conn, "task_chains", "workflow_def_ref") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN workflow_def_ref TEXT NOT NULL DEFAULT '';") do return false
	if !sqlite_object_exists(conn, "mixed_work_engine_epoch") && !table_column_exists(conn, "task_chains", "workflow_snapshot_json") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN workflow_snapshot_json TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "defaults_json") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN defaults_json TEXT NOT NULL DEFAULT '{}';") do return false
	if !table_column_exists(conn, "task_chain_fleets", "roles_json") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN roles_json TEXT NOT NULL DEFAULT '[\"worker\"]';") do return false
	if !table_column_exists(conn, "task_chain_fleets", "bridge_id") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	if !sqlite_object_exists(conn, "mixed_work_engine_epoch") && !exec(conn, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_chain_stage ON tasks(chain_id, stage_key, stage_index) WHERE stage_key <> '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_chain_state ON tasks(chain_id, state);") do return false
	// M1 review follow-ups (additive, idempotent): idle_since lets the Idle_TTL
	// timer detect a moved deadline and be rebuilt on boot (S4); extended_at
	// records the one-shot clock-jump extension on the lease row (S5).
	if !table_column_exists(conn, "agent_instances", "idle_since") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN idle_since TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_leases", "extended_at") && !exec(conn, "ALTER TABLE task_leases ADD COLUMN extended_at TEXT NOT NULL DEFAULT '';") do return false
	// Legacy drops (tolerant; see the proc comment).
	drop_legacy_column(conn, "tasks", "status")
	drop_legacy_column(conn, "tasks", "assignee_ref_json")
	drop_legacy_column(conn, "tasks", "reviewer_refs_json")
	drop_legacy_column(conn, "task_chains", "default_reviewer_refs_json")
	if !exec(conn, "DROP TABLE IF EXISTS task_votes;") do return false
	if !exec(conn, "DROP TABLE IF EXISTS task_subscriptions;") do return false
	return true
}

// drop_legacy_column drops a column if it still exists, logging (not failing)
// when SQLite refuses. See upgrade_task_v2_schema for why that is acceptable.
drop_legacy_column :: proc(conn: ^Conn, table, column: string) {
	if !table_column_exists(conn, table, column) do return
	stmt := fmt.tprintf("ALTER TABLE %s DROP COLUMN %s;", table, column)
	if !exec(conn, stmt) {
		fmt.eprintfln("[migrations] task v2: could not drop legacy column %s.%s (left in place; the engine never reads it)", table, column)
	}
}

// upgrade_vault_directory_schema is the idempotent self-heal twin of migration 092:
// the file is written with IF NOT EXISTS throughout, so it is simply re-run.
upgrade_vault_directory_schema :: proc(conn: ^Conn) -> bool {
	if !exec(conn, MIGRATION_092_VAULT_DEVICE_DIRECTORY) do return false
	// 100's column on a table 092 created before it existed (CREATE IF NOT EXISTS keeps the old shape).
	if !table_column_exists(conn, "vault_devices", "pair_hub_origin") {
		return exec(conn, MIGRATION_100_VAULT_PAIR_HUB_ORIGIN)
	}
	return true
}



// upgrade_shell_sessions_kind_and_key_schema is the idempotent self-heal twin of
// migration 048, for a database whose ledger says 041 ran but which predates 048
// (or was bootstrapped from a stale embedded copy). It re-runs the migration's
// SQL, which is written to be safe on an already-migrated table: the UPDATEs and
// the DELETE match nothing once the vocabulary is collapsed, and the rebuild is
// skipped entirely when shell_sessions_owner_session already exists.
//
// KEYED ON THE SAME LAST OBJECT as the skip guard, deliberately. This twin is the
// path that REPAIRS a database 048 did not fully reach, so it is the last place that
// should refuse to run because an EARLY object of 048 happens to be present.
upgrade_shell_sessions_kind_and_key_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if sqlite_object_exists(conn, "shell_sessions_owner_session") do return true
	return exec(conn, MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY)
}

// upgrade_shell_sessions_background_schema is the idempotent self-heal twin of
// migration 049 (REQ-SHELL-2), for the same class of database 048's twin exists
// for.
//
// It is per-COLUMN rather than one exec of the migration file, because 049 is
// ALTER TABLE ADD COLUMN and SQLite has no IF NOT EXISTS for that: a single
// re-exec is a hard "duplicate column name" error that would fail startup. The
// two columns are also checked independently, so a database that somehow got one
// of them gains the other instead of being stuck.
upgrade_shell_sessions_background_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if !table_column_exists(conn, "shell_sessions", "background") {
		if !exec(conn, "ALTER TABLE shell_sessions ADD COLUMN background INTEGER NOT NULL DEFAULT 0;") do return false
	}
	if !table_column_exists(conn, "shell_sessions", "conversation_id") {
		if !exec(conn, "ALTER TABLE shell_sessions ADD COLUMN conversation_id TEXT NOT NULL DEFAULT '';") do return false
	}
	return exec(
		conn,
		"CREATE INDEX IF NOT EXISTS shell_sessions_conversation ON shell_sessions(owner_user_id, conversation_id);",
	)
}

// upgrade_shell_sessions_run_seq_schema is the idempotent self-heal twin of
// migration 051 (REQ-SHELL-4), for the same class of database the three twins above
// exist for.
//
// SINGLE-OBJECT, so it is the simplest of the four: 051 adds one column and creates
// no index (run_seq is read from a row already fetched by primary key and is never
// a lookup key — see the migration file), so there is no second half that a
// non-transactional pass could leave missing. The existence check is still required,
// because ALTER TABLE ADD COLUMN is not idempotent in SQLite.
upgrade_shell_sessions_run_seq_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if table_column_exists(conn, "shell_sessions", "run_seq") do return true
	return exec(conn, "ALTER TABLE shell_sessions ADD COLUMN run_seq INTEGER NOT NULL DEFAULT 0;")
}

// upgrade_shell_sessions_kill_intent_schema is the idempotent self-heal twin of
// migration 050 (REQ-SHELL-3), for the same class of database 048's and 049's
// twins exist for.
//
// PER-OBJECT, and both objects are checked independently — the column AND the
// partial index. 050 creates two objects and run_migrations is not transactional,
// so "the column exists" does not imply "the index exists": a pass that died
// between them leaves exactly that state, and a twin that checked only the column
// would leave the replay lookup without its index forever. Checking each half
// separately means a database that somehow got one gains the other instead of
// being stuck with half a migration.
upgrade_shell_sessions_kill_intent_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if !table_column_exists(conn, "shell_sessions", "kill_requested_at") {
		if !exec(conn, "ALTER TABLE shell_sessions ADD COLUMN kill_requested_at TEXT NOT NULL DEFAULT '';") do return false
	}
	// CREATE INDEX IF NOT EXISTS is idempotent on its own, unlike ADD COLUMN, so this
	// needs no existence check of its own — it is the statement that repairs the
	// partial-apply case the guards above are keyed on.
	return exec(
		conn,
		"CREATE INDEX IF NOT EXISTS shell_sessions_pending_kill ON shell_sessions(bridge_id) WHERE kill_requested_at != '';",
	)
}

upgrade_bridge_version_and_updates_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "bridges") do return true
	if !table_column_exists(conn, "bridges", "version") && !exec(conn, "ALTER TABLE bridges ADD COLUMN version TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "commit_sha") && !exec(conn, "ALTER TABLE bridges ADD COLUMN commit_sha TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "build_timestamp") && !exec(conn, "ALTER TABLE bridges ADD COLUMN build_timestamp TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "update_status") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_status TEXT NOT NULL DEFAULT 'idle';") do return false
	if !table_column_exists(conn, "bridges", "update_error") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_error TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_bridge_update_progress_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "bridges") do return true
	if !table_column_exists(conn, "bridges", "update_message") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_message TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "update_progress") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_progress INTEGER NOT NULL DEFAULT 0;") do return false
	return true
}

upgrade_memory_action_expiry_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "memories") do return true
	if !table_column_exists(conn, "memories", "expires_at") {
		if !exec(conn, "ALTER TABLE memories ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';") do return false
	}
	return true
}
