# Heimdall Memory System Architecture and Agent Run-Dir Bootstrapping

## 1. Executive Overview & System Architecture

Heimdall incorporates a federated, multi-tier memory and skill bootstrapping system designed to provide autonomous AI agents with durable, context-aware knowledge across sessions and task chains without incurring unbounded prompt token overhead.

The memory subsystem is distributed across three operational tiers:
1. **The Heimdall Hub**: The central orchestrator and source of truth. It manages the relational database (SQLite), performs multi-dimensional targeting resolution, implements strict Human-in-the-Loop (HITL) authorization gates, and compiles customized bootstrap payloads for launching agents.
2. **The Heimdall Bridge**: The host-level daemon that manages local agent execution. It executes the physical bootstrap handshake (`bridge_bootstrap_fetch_and_materialize`), caches content-addressed blobs, writes configuration files (`AGENTS.md`/`CLAUDE.md`), materializes skills into the agent's workspace, injects authenticated CLI wrappers, and tracks managed state via an immutable manifest.
3. **The Agent CLI (`ham-ctl`)**: The operational interface available within an agent's run directory (`./bin/ham-ctl`). It allows agents to discover active memories, inspect historical context, and propose new durable learnings back to the Hub through authenticated RPC envelopes.

```
                      +---------------------------------------+
                      |             Heimdall Hub              |
                      | - SQLite Database (memories, cards)   |
                      | - Targeting Resolution Engine         |
                      | - HITL Action Card Approval Pipeline  |
                      | - Manifest & Prompt Compiler          |
                      +-------------------+-------------------+
                                          |
                      HTTP REST / Blobs   | /api/v1/bridge/...
                      (Bearer Bridge Tok) | /api/v1/agent-actions/...
                                          |
                      +-------------------v-------------------+
                      |            Heimdall Bridge            |
                      | - Bootstrap Handshake Orchestrator    |
                      | - Content-Addressed Blob Cache        |
                      | - Run Directory Materializer          |
                      +-------------------+-------------------+
                                          |
                        Local File System | Unix Domain Socket /
                         & Environment    | Bridge RPC
                                          |
                      +-------------------v-------------------+
                      |      Agent Instance Run Directory     |
                      | - AGENTS.md / CLAUDE.md               |
                      | - .agents/skills/<name>/SKILL.md      |
                      | - bin/ham-ctl (CLI shim)              |
                      | - heimdall-bootstrap-manifest.json    |
                      +---------------------------------------+
```

---

## 2. Core Data Model & Memory Types (REQ-MEM-ARCH-1 §1)

### 2.1 Domain Definition & Schema

The core memory data structures are defined in `src/hub/domain/content.odin:5-69` and `src/contracts/memory_provider.odin:1-55`. In the Hub domain, a Memory is represented as:

```odin
// src/hub/domain/content.odin:48-69
Memory :: struct {
    memory_id:     string,
    owner_user_id: User_ID,
    // Targeting lists per dimension (JSON arrays in SQLite)
    agent_ids:     []string,
    project_ids:   []Project_ID,
    template_ids:  []string,
    bridge_ids:    []string,
    type:          Memory_Type,
    status:        string,
    title:         string,
    description:   string,
    body:          string,
    evidence:      string,
    expires_at:    string,
    created_at:    string,
    updated_at:    string,
}
```

### 2.2 The 5 Canonical Memory Types

Heimdall categorizes durable knowledge into five distinct memory types (`src/hub/domain/content.odin:5-28`):

| Memory Type | Primary Purpose | Lifecycle & Prompt Materialization |
| :--- | :--- | :--- |
| **`fact`** | Environmental facts, platform quirks, build commands, hardware invariants, and codebase architecture. | Inlined directly into the agent's bootstrap markdown (`AGENTS.md`) under `## Applicable Memories`. |
| **`habit`** | Operational behaviors, coding standards, verification checklists, communication norms, and workflows. | Inlined directly into the agent's bootstrap markdown (`AGENTS.md`) under `## Applicable Memories`. |
| **`episode`** | Structured narrative records of past task completions, incident post-mortems, or debugging sessions. | Excluded from inline bootstrap prompts to prevent prompt bloat. Retained in DB for query-time retrieval via `ham-ctl memory list/show`. |
| **`expertise`** | In-depth domain knowledge, algorithm explanations, or subsystem designs. | Excluded from inline bootstrap prompts to prevent prompt bloat. Retained in DB for on-demand inspection. |
| **`skill`** | Executable, procedural capabilities formatted as markdown workflows with YAML frontmatter. | Filtered out of inline prompt text; materialized by the Bridge into distinct files at `.agents/skills/<name>/SKILL.md`. |

#### Why `template` is a Targeting Scope, Not a Memory Type
In early contract iterations (`src/contracts/memory_provider.odin:9`), `Template` was transiently placed inside the `Memory_Type` enum. However, the production architecture cleanly separated targeting dimensions from content classifications:
- A **Template** (e.g., `coder`, `reviewer`, `curator`) is an agent archetype or persona that defines system instructions and behavioral baselines.
- A **Memory** is declarative knowledge applied *to* agents.
- Therefore, `template` was removed from `domain.Memory_Type` and established as a first-class targeting dimension (`template_ids`). Memories of type `fact`, `habit`, or `skill` can be targeted to specific agent templates (for instance, a habit memory outlining code review checklists targeted exclusively to `template_ids: ["tmpl_reviewer"]`).

### 2.3 Status Lifecycle & State Machine

A memory moves through four discrete states:

```
   [ Agent or User ]
          |
   propose_memory()
          |
          v
     +----------+          Operator Rejection
     | proposed | -----------------------------------> [ rejected ]
     | (pending)|
     +----+-----+
          |
          | Operator Approval (Action Card: memory.approve)
          v
      +--------+           Operator Retirement
      | active | -----------------------------------> [ archived ]
      +--------+
```

1. **`proposed` (or `pending`)**: Created when an agent calls `ham-ctl memory propose ...` or an API client proposes knowledge. A pending proposal is not considered active, is ignored by bootstrap prompt compilers, and carries a default 24-hour expiration TTL (`expires_at`).
2. **`active`**: Promoted only when a human operator approves the proposal via an Action Card (`memory.approve`) or explicit operator CLI command. Active memories are evaluated by the targeting resolution engine during agent bootstrap.
3. **`archived`**: Retired memories that are no longer applied during bootstrap but are preserved in SQLite for historical audits.
4. **`rejected`**: Discarded proposals that failed operator review.

### 2.4 SQLite Schema Evolution & Migrations

The database representation evolved across several key migrations in `src/hub/repository/sqlite/migrations/`:
- **`015_memory_target_scope.sql`**: Added initial scalar targeting columns:
  ```sql
  ALTER TABLE memories ADD COLUMN project_id TEXT NOT NULL DEFAULT '';
  ALTER TABLE memories ADD COLUMN template_id TEXT NOT NULL DEFAULT '';
  ALTER TABLE memories ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';
  ```
- **`026_memory_scope_lists.sql`**: Converted single scalar columns to multi-tenant JSON array columns (`TEXT NOT NULL DEFAULT '[]'`). An empty array (`'[]'`) signifies universal scope, while a populated array restricts applicability to matching IDs:
  ```sql
  ALTER TABLE memories ADD COLUMN agent_ids TEXT NOT NULL DEFAULT '[]';
  ALTER TABLE memories ADD COLUMN project_ids TEXT NOT NULL DEFAULT '[]';
  ALTER TABLE memories ADD COLUMN template_ids TEXT NOT NULL DEFAULT '[]';
  ALTER TABLE memories ADD COLUMN bridge_ids TEXT NOT NULL DEFAULT '[]';
  UPDATE memories SET
    agent_ids = CASE WHEN agent_id = '' THEN '[]' ELSE '["' || agent_id || '"]' END,
    project_ids = CASE WHEN project_id = '' THEN '[]' ELSE '["' || project_id || '"]' END,
    template_ids = CASE WHEN template_id = '' THEN '[]' ELSE '["' || template_id || '"]' END,
    bridge_ids = CASE WHEN bridge_id = '' THEN '[]' ELSE '["' || bridge_id || '"]' END;
  ALTER TABLE memories DROP COLUMN agent_id;
  ALTER TABLE memories DROP COLUMN project_id;
  ALTER TABLE memories DROP COLUMN template_id;
  ALTER TABLE memories DROP COLUMN bridge_id;
  ```
- **`028_memory_description_and_cleanup.sql`**: Added `description TEXT NOT NULL DEFAULT ''` for concise summary previews and removed legacy hardcoded system skill seeds.
- **`055_memory_action_expiry.sql`**: Added `expires_at TEXT NOT NULL DEFAULT ''` and updated pending proposals to expire 24 hours after creation.

---

## 3. Targeting Scope & Resolution Engine (REQ-MEM-ARCH-1 §2)

### 3.1 The Four Targeting Dimensions

Every memory defines four orthogonal targeting scope arrays. When resolving whether a memory applies to an agent instance, Heimdall evaluates these dimensions:

1. **`agent_ids` (`[]string`)**: Targets specific durable agent identities (`agt_...`). Useful for personal habits, learning history, and persistent agent identities across tasks.
2. **`project_ids` (`[]Project_ID`)**: Targets specific code repositories or workspaces (`proj_...`). Encapsulates project build commands, testing frameworks, and repository conventions.
3. **`template_ids` (`[]string`)**: Targets agent personas or templates (e.g., `tmpl_worker`, `tmpl_reviewer`). Enforces role-specific protocols.
4. **`bridge_ids` (`[]string`)**: Targets specific physical or virtual bridge execution hosts (`brg_...`). Used for host-specific paths, environment variables, local hardware constraints, or isolated ports.
5. **Global Scope**: An empty array (`[]`) in all four dimensions designates a globally applicable memory that matches every agent, project, template, and bridge across the owner's domain.

### 3.2 The Conjunctive AND Resolution Rule

Targeting dimensions are evaluated conjunctively (**AND**). Every non-empty list must contain the corresponding attribute of the agent instance. If any non-empty list fails to match, the memory is excluded.

The resolution logic is implemented in `src/hub/service/agent/agent_service.odin:513-540`:

```odin
// src/hub/service/agent/agent_service.odin:513-524
bootstrap_memory_applies :: proc(
    m: domain.Memory, 
    service: ^Agent_Service, 
    owner: domain.User_ID, 
    inst: domain.Agent_Instance,
) -> bool {
    // 1. Only active memories are eligible for bootstrap
    if m.status != "active" do return false
    
    // 2. Durable agent ID matching (empty list = matches all)
    if !memory_list_matches(m.agent_ids, inst.agent_id) do return false
    
    // 3. Project ID matching (empty list = matches all)
    if !memory_project_list_matches(m.project_ids, inst.project_id) do return false
    
    // 4. Template matching: resolves the agent record to inspect its template_id
    if len(m.template_ids) > 0 {
        if service == nil || service.agents == nil || strings.trim_space(inst.agent_id) == "" do return false
        agent, ok, _ := iface.agent_get(service.agents, inst.agent_id)
        if !ok || agent.owner_user_id != owner || !memory_list_contains(m.template_ids, agent.template_id) do return false
    }
    
    // 5. Bridge host matching (empty list = matches all)
    if !memory_list_matches(m.bridge_ids, inst.bridge_id) do return false
    
    return true
}

memory_list_matches :: proc(list: []string, value: string) -> bool {
    if len(list) == 0 do return true // Empty list matches any target
    return memory_list_contains(list, value)
}
```

### 3.3 Agent-Keyed Resolution for Manifest Caching

In addition to per-instance resolution, the Hub implements `bootstrap_memory_applies_agent` (`src/hub/service/agent/agent_service.odin:2270-2288`) for the cached manifest endpoint (`/api/v1/bridge/agents/{agent_id}/bootstrap-manifest`).

Because manifests are content-addressed and shared across homogeneous instances of an agent on a given bridge, resolution is performed against:
- The durable `agent` entity.
- The `project_id`.
- The authenticated `bridge_id` extracted from the requesting bridge's Bearer token.

Threading `bridge_id` into the cache key guarantees that bridge-scoped memories never leak across different host environments while preserving HTTP 304 Not Modified cache hits.

---

## 4. Memory Creation & Human-in-the-Loop Governance (REQ-MEM-ARCH-1 §3)

### 4.1 CLI Invocation

Agents propose memories using the managed wrapper script:

```bash
./bin/ham-ctl memory propose \
  --type fact \
  --title "Odin collection build flag" \
  --body "Always specify -collection:odin_test=src when running odin test." \
  --evidence "Observed build failure without collection mapping in src/hub." \
  --project-ids proj_18c6879e443756f1
```

If `--agent-ids` is omitted by the proposer, the CLI default scopes the proposal to the proposing agent's own durable identity, preventing accidental cross-agent contamination.

### 4.2 RPC Routing and Network Path

```
 [ham-ctl memory propose]
            |
            | 1. JSON-RPC: {"method": "agent.memory.propose", "params": {...}}
            v
 [Bridge Agent API Listener] (src/bridge/agent_api.odin:205)
            |
            | 2. HTTP POST with Bearer Instance Token
            v
 [Hub Agent Action Handler] (src/hub/transport/http/agent_action_handlers.odin:1018)
    - Validates instance token (require_instance_action_auth)
    - Validates target ownership (validate_memory_targets)
    - Calls content_service.create_memory()
            |
            v
 [Content Repository] -> Status: "pending", expires_at: now + 24h
            |
            v
 [Card Service Engine] (src/hub/service/card/card_service.odin:457)
    - Detects pending proposal
    - Automatically creates Action Card: crd_...
```

1. **Local RPC**: `ham-ctl` connects to the local bridge socket and sends an `agent.memory.propose` RPC payload.
2. **Bridge Forwarding**: The Bridge (`src/bridge/agent_api.odin:205`) inspects the route and translates it to an authenticated envelope sent to the Hub endpoint `POST /api/v1/agent-actions/memory/propose`.
3. **Hub Ingestion**: `agent_action_memory_propose_handler` authenticates the instance token, validates that all specified targeting IDs exist and belong to the calling user (`validate_memory_targets`), and persists the memory with status `"pending"`.

### 4.3 Action Card Generation & HITL Verification

Heimdall strictly enforces that **agents can never unilaterally approve their own memories**. Durable memory insertion requires operator verification.

The Hub's Card Service (`src/hub/service/card/card_service.odin:457-480`) periodically scans for pending memories and generates an Action Card:
- **Card Title**: `Review memory proposal: <title>`
- **Card Operation**:
  ```json
  [
    {
      "op": "memory.approve",
      "label": "Approve memory proposal: <title>",
      "args": {
        "memory_id": "mem_18db..."
      }
    }
  ]
  ```
- **Guard Condition**: `{"memory_proposal_id": "mem_...", "expected_status": "pending"}`
- **Expiration**: Synchronized with the memory proposal's TTL (`expires_at`, 24 hours).

When the human operator accepts the card in the Heimdall UI (or via `ham-ctl action accept` with user authentication), `card_service.odin:895` executes `content_service.approve_memory(...)`:
- Sets `status = "active"`.
- Updates `updated_at = platform.clock_now()`.
- Invalidates cached bootstrap manifests, making the memory immediately visible to future agent launches.

---

## 5. Agent Run Directory Bootstrapping Lifecycle (REQ-MEM-ARCH-1 §4)

When an agent instance is launched or restarted, the Bridge and Hub perform a tightly coordinated handshake that materializes the execution environment in the instance's unique run directory (`/tmp/heimdall-bridge-local/instances/<instance_id>`).

```
+----------------+                                              +---------------+
| Heimdall Bridge|                                              |  Heimdall Hub |
+-------+--------+                                              +-------+-------+
        |                                                               |
        | 1. GET /api/v1/bridge/agent-instances/{id}/bootstrap         |
        |    (Bearer Bridge Token)                                      |
        +-------------------------------------------------------------->|
        |                                                               |
        |                               2. Execute bootstrap resolution |
        |                                  - Filter active memories     |
        |                                  - Inline facts & habits      |
        |                                  - Render skill payloads      |
        |                                                               |
        | 3. HTTP 200 OK (Bootstrap JSON payload:                      |
        |    content, skills[], variables)                              |
        |<--------------------------------------------------------------+
        |
        | 4. Materialize AGENTS.md / CLAUDE.md
        | 5. Materialize .agents/skills/<name>/SKILL.md
        | 6. Inject bin/ham-ctl (CLI shim with tokens)
        | 7. Write heimdall-bootstrap-manifest.json
        v
 [Agent Process Spawn]
```

### 5.1 Launch Trigger & Manifest Retrieval

The Bridge initiates the bootstrap sequence in `src/bridge/bootstrap_service.odin:39-61` (`bridge_bootstrap_fetch_and_materialize`):
```odin
path := strings.concatenate({"/api/v1/bridge/agent-instances/", instance_id, "/bootstrap"})
headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
resp, ok := bridge_http_request_retry("GET", hub_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
```

The Hub handler (`bridge_instance_bootstrap_handler` in `src/hub/transport/http/bridge_handlers.odin:1950`) calls `agent_service.bootstrap_manifest_json_for_bridge`.

### 5.2 Hub Assembly: Inlining vs. External Skill Materialization

Inside `src/hub/service/agent/agent_service.odin:1900-1988`:

#### 1. Inlined Memories (Facts & Habits)
The Hub compiles prompt-level memories via `write_bootstrap_memory_markdown` (`agent_service.odin:480-498`):
- Only memories of type `.Fact` and `.Habit` that satisfy `bootstrap_memory_applies` are included.
- They are rendered into the primary markdown prompt under `## Applicable Memories`:
  ```markdown
  ## Applicable Memories

  ### Odin collection build flag
  Type: fact

  Always specify -collection:odin_test=src when running odin test.
  ```
- **Prompt Token Protection**: Memories of type `skill`, `episode`, and `expertise` are explicitly excluded from the markdown body. This prevents context exhaustion and model confusion.

#### 2. Skill Payloads & Content-Addressed Manifests
- Static system skills (`STATIC_SKILLS`, generated from `src/prompts/skills/`) and dynamic active `.Skill` memories are processed into individual skill items.
- For each dynamic skill memory, `render_skill` (`agent_service.odin:1776`) extracts or synthesizes YAML frontmatter (`name`, `description`, `heimdall_managed: true`) and markdown instructions.
- The content is hashed using SHA256 (`bootstrap_fragment_hash`) and stored in the Hub's memory cache.
- The bootstrap response embeds each skill in the `skills` array:
  ```json
  {
    "skills": [
      {
        "kind": "SKILL",
        "name": "worker-task-management",
        "target_hint": ".agents/skills/worker-task-management/SKILL.md",
        "hash": "a1b2c3..."
      }
    ]
  }
  ```

### 5.3 Bridge Materialization (`bridge_bootstrap_fetch_and_materialize`)

Upon receiving the bootstrap response, the Bridge unpacks the payload directly into the agent's instance directory:

1. **Bootstrap Prompt Document**:
   - Resolves provider profile filename via `bridge_bootstrap_agents_md_name` (`CLAUDE.md` for Claude providers, `AGENTS.md` for others).
   - Deletes any stale bootstrap files (`bridge_bootstrap_cleanup_stale_agents_md`).
   - Writes the compiled markdown file to `run_dir/AGENTS.md`.
2. **Skill Materialization (`bridge_bootstrap_write_skills`)**:
   - Iterates through the `skills` payload.
   - For each entry, resolves its relative target path (`.agents/skills/<skill-name>/SKILL.md`).
   - Creates directories and writes the skill file (`bridge_bootstrap_write_skill_file`).
3. **CLI Wrapper Shim (`bridge_bootstrap_write_ham_ctl_wrapper`)**:
   - Creates directory `run_dir/bin`.
   - Generates an executable shell script at `bin/ham-ctl`:
     ```sh
     #!/bin/sh
     export HEIMDALL_BRIDGE_ENDPOINT="unix:/tmp/bridge.sock" # or http host
     export HEIMDALL_AGENT_TOKEN="hlat_..."
     export HEIMDALL_AGENT_INSTANCE_ID="inst_..."
     exec /usr/local/bin/ham-ctl "$@"
     ```
   - Sets executable permissions (`chmod +x`). This ensures the agent can immediately interact with Heimdall without needing to configure environment variables.
4. **Bootstrap Manifest Registration**:
   - Compiles a manifest tracking every file created during bootstrap.
   - Writes `run_dir/heimdall-bootstrap-manifest.json`:
     ```json
     {
       "agent_instance_id": "inst_18dbaae8be265355",
       "managed_files": [
         {"relative_path": "AGENTS.md", "kind": "AGENTS_MD"},
         {"relative_path": "bin/ham-ctl", "kind": "CTL_WRAPPER"},
         {"relative_path": ".agents/skills/worker-task-management/SKILL.md", "kind": "SKILL"},
         {"relative_path": ".agents/skills/ham-ctl-reference/SKILL.md", "kind": "SKILL"}
       ]
     }
     ```

---

## 6. Comprehensive Verification and Reference Guide

### 6.1 Inspecting Active and Pending Memories

```bash
# List all active memories applying to the current agent
./bin/ham-ctl memory list --status active

# List memories filtered by type
./bin/ham-ctl memory list --type fact
./bin/ham-ctl memory list --type habit
./bin/ham-ctl memory list --type skill

# Inspect memory details and evidence
./bin/ham-ctl memory show mem_18dbaae8...

# Output raw body of a memory
./bin/ham-ctl memory content mem_18dbaae8...
```

### 6.2 Proposing Scoped Memories

```bash
# Propose a project-scoped habit memory
./bin/ham-ctl memory propose \
  --type habit \
  --title "Always run unit tests before task handoff" \
  --body "Run odin test src/hub -collection:odin_test=src before submitting in_validation." \
  --project-ids proj_18c6879e443756f1

# Propose a template-scoped skill memory
./bin/ham-ctl memory propose \
  --type skill \
  --title "automated-performance-benchmarking" \
  --body "---\nname: automated-performance-benchmarking\ndescription: Run benchmark suites\n---\n# Automated Benchmarking\n..." \
  --template-ids tmpl_worker
```

### 6.3 Verifying Run-Dir Bootstrap Artifacts

From within any active agent run directory:
```bash
# Verify the generated manifest
cat heimdall-bootstrap-manifest.json | jq .

# Verify inlined memories in AGENTS.md
grep -A 20 "## Applicable Memories" AGENTS.md

# Verify materialized skills
ls -la .agents/skills/

# Verify CLI wrapper execution
./bin/ham-ctl context get
```

---

## 7. Architectural Summary Matrix

| Concern | Implementation Mechanism | Governing Files |
| :--- | :--- | :--- |
| **Data Storage** | SQLite tables `memories`, `cards` with JSON array columns | `src/hub/repository/sqlite/migrations/026_memory_scope_lists.sql` |
| **Domain Logic** | Enums `Memory_Type`, struct `Memory` | `src/hub/domain/content.odin:5-69` |
| **Targeting Resolution** | Multi-dimensional conjunctive AND evaluation | `src/hub/service/agent/agent_service.odin:513-540` |
| **Agent Propose RPC** | CLI -> Bridge RPC (`agent.memory.propose`) -> Hub REST | `src/bridge/agent_api.odin:205`, `src/hub/transport/http/agent_action_handlers.odin:1018` |
| **Operator Gate** | Action Card generation (`memory.approve`), 24h TTL | `src/hub/service/card/card_service.odin:457-480, 895-907` |
| **Prompt Assembly** | Inlines `fact` & `habit`; filters out `skill`, `episode`, `expertise` | `src/hub/service/agent/agent_service.odin:480-498, 1685-1710` |
| **Run-Dir Materialization**| Unpacks `AGENTS.md`, materializes skills, writes CLI wrapper | `src/bridge/bootstrap_service.odin:39-95` |
| **Integrity Tracking** | `heimdall-bootstrap-manifest.json` | `src/bridge/bootstrap_service.odin:52-59` |
