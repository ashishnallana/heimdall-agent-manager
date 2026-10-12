#!/usr/bin/env python3
"""Static regression for Bridge skill bootstrap materialization."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROVIDER_STORE = ROOT / "src" / "bridge" / "provider_store.odin"
BOOTSTRAP = ROOT / "src" / "bridge" / "bootstrap_service.odin"
AGENT_SERVICE = ROOT / "src" / "hub" / "service" / "agent" / "agent_service.odin"
STATIC_SKILLS_GEN = ROOT / "src" / "hub" / "service" / "agent" / "static_skills_gen.odin"
HAM_CTL_COMM_SKILL = ROOT / "src" / "prompts" / "skills" / "heimdall-ctl-communication" / "SKILL.md"
TASKCHAIN_OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"
DOMAIN_CONTENT = ROOT / "src" / "hub" / "domain" / "content.odin"
CONTENT_REPO = ROOT / "src" / "hub" / "repository" / "sqlite" / "content_repo_sqlite.odin"
CONTENT_SERVICE = ROOT / "src" / "hub" / "service" / "content" / "content_service.odin"
CONTENT_HANDLERS = ROOT / "src" / "hub" / "transport" / "http" / "content_handlers.odin"
MIGRATIONS = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations.odin"
MEMORY_CATALOG = ROOT / "src" / "ui" / "api" / "memoryCatalog.ts"


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def main() -> None:
    provider_store = PROVIDER_STORE.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    agent_service = AGENT_SERVICE.read_text(encoding="utf-8")
    overview = TASKCHAIN_OVERVIEW.read_text(encoding="utf-8")
    domain_content = DOMAIN_CONTENT.read_text(encoding="utf-8")
    content_repo = CONTENT_REPO.read_text(encoding="utf-8")
    content_service = CONTENT_SERVICE.read_text(encoding="utf-8")
    content_handlers = CONTENT_HANDLERS.read_text(encoding="utf-8")
    migrations = MIGRATIONS.read_text(encoding="utf-8")
    memory_catalog = MEMORY_CATALOG.read_text(encoding="utf-8")

    # The provider skill dir comes from the provider catalog (37df8fb1 replaced the
    # seed table, per-bridge override and UI editor).
    for marker in [
        "bridge_provider_default_skill_dir",
        "bridge_provider_catalog_profile(strings.trim_space(provider)); ok do return profile.skill_dir",
    ]:
        require(marker in provider_store, f"provider skill dir must derive from the catalog: {marker}")

    for marker in [
        "bridge_bootstrap_write_skills",
        "bridge_provider_json_extract_array(body, \"skills\")",
        "bridge_provider_json_top_level_objects(skills_array)",
        "if skill_dir == \"\" do skill_dir = bridge_provider_default_skill_dir(provider)",
        "bridge_bootstrap_write_skill_file(run_dir, path, content)",
        "bridge_bootstrap_write_skill_file(run_dir, skill_path, skill_content)",
    ]:
        require(marker in bootstrap, f"Bridge bootstrap must materialize all skill files: {marker}")

    # Memory scoping is a LIST model now: project_ids/template_ids/bridge_ids are
    # matched with list helpers (an empty list = applies to all).
    for marker in [
        "bootstrap_append_static_skills",
        "STATIC_SKILLS",
        "\\\"skills\\\":[",
        "m.type != .Skill",
        "bootstrap_memory_applies(m, service, owner, inst)",
        "domain.memory_type_string(m.type)",
        "memory_project_list_matches(m.project_ids, inst.project_id)",
        "memory_list_contains(m.template_ids, agent.template_id)",
        "memory_list_matches(m.bridge_ids, inst.bridge_id)",
    ]:
        require(marker in agent_service, f"hub bootstrap should emit scoped matching skills: {marker}")

    # The former inline CLI-communication skill text now ships as a compile-time
    # static SKILL.md served to every agent via STATIC_SKILLS (gen_static_skills).
    static_skills_gen = STATIC_SKILLS_GEN.read_text(encoding="utf-8")
    require("heimdall-ctl-communication" in static_skills_gen, "static skills must include the ham-ctl communication skill")
    require("ham-ctl-reference" in static_skills_gen, "static skills must include the ham-ctl reference skill")
    ctl_comm_skill = HAM_CTL_COMM_SKILL.read_text(encoding="utf-8")
    require("./.heimdall/bin/ham-ctl" in ctl_comm_skill, "ham-ctl communication skill must document the managed ham-ctl path")

    # AGENTS.md inline memory must be fact/habit only. Skill (and other) memory
    # types are materialized as separate SKILL.md files and must NOT be dumped
    # inline (that pollutes the bootstrap doc). Both inline renderers guard this.
    require(
        agent_service.count("if m.type != .Fact && m.type != .Habit do continue") >= 2,
        "both inline AGENTS.md memory renderers must restrict to fact+habit",
    )
    require(
        "## Applicable Memories / Skills" not in agent_service,
        "inline AGENTS.md memory heading must not advertise skills",
    )
    require(
        "## Applicable Memories" in agent_service,
        "inline AGENTS.md memory heading should be '## Applicable Memories'",
    )

    for marker in [
        "Memory_Type :: enum",
        "Fact,",
        "Habit,",
        "Episode,",
        "Expertise,",
        "Skill,",
    ]:
        require(marker in domain_content, f"memory kind should be enum without template kind: {marker}")
    require("Template," not in domain_content, "template must not be a memory kind")
    require(
        "project_ids: []Project_ID" in domain_content
        and "template_ids: []string" in domain_content
        and "bridge_ids: []string" in domain_content,
        "memory scopes must be optional id LISTS (project_ids/template_ids/bridge_ids)",
    )

    for marker in [
        "agent_ids, project_ids, template_ids, bridge_ids, type",
        "domain.memory_type_string(m.type)",
        "domain.memory_type_from_string(column_text",
    ]:
        require(marker in content_repo, f"content repository must persist scoped enum memory: {marker}")

    for marker in [
        "json_string_array(body,\"bridge_ids\")",
        "json_project_id_array(body,\"project_ids\")",
        "bridge_owned",
        "domain.memory_type_from_string(json_string(body,\"type\"))",
        "has_bridge_ids",
        "validate_memory_targets",
    ]:
        require(marker in content_service + content_handlers, f"memory API must accept optional scopes: {marker}")

    require("upgrade_memory_target_scope_schema" in migrations and "bridge_ids" in migrations, "migration upgrade must add optional memory scope lists")
    require("targetBridgeId" in memory_catalog and "targetTemplateId" in memory_catalog, "UI memory catalog must normalize/filter bridge/template scopes")

    agents_md = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    require('data-debug-id={`taskchain-task-description-${taskId}`}' in overview, "chat task chain task rows must show task descriptions")
    require('taskchain-task-description-${taskId}' in agents_md, "task description debug id must be documented")
    require('<Markdown source={description}' in overview, "task descriptions should render as markdown (preserving line breaks/formatting)")

    print("PASS: bridge bootstrap skills static")


if __name__ == "__main__":
    main()
