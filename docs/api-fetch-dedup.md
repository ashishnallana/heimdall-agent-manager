# API fetch deduplication

## Scope and ancestry

Worktree /home/tanmay/hamwt/api-fetch-dedup, branch api-fetch-dedup.
Base ae2728d78e42fc11c172cf93983598354bf784db (fresh origin/main v0.4.27).
Task-1 commits a17227e5 and 56c3c313 were cherry-picked as ff7507fb and cfe5316d.
The unrelated shared checkout was neither edited nor switched.

REQ-CALL/REQ-CACHE: reuse existing RTK deduplication and WS invalidation; eliminate unused search SQL. No new cache, auth behavior, event contract, durability or production change.

## Endpoint callers and decisions

| Endpoint | Remaining callers / duplicates | Decision |
|---|---|---|
| GET /shells | RTK listShells (src/ui/api/endpoints/shells.ts) keys mounted per tab: AppShell.tsx:1531 status bar {status:'live',limit:200}, always mounted; ShellLaunchPanel.tsx:76, ShellMainPane.tsx:188 and RunningShellSelectorModal.tsx:23 (when open) share that exact key and are already deduplicated by RTK; AuxNewTabLauncher.tsx:56 {chainId or bridgeId,status:'live'}; ShellRunIndicator.tsx:53 useConversationRuns {agentInstanceId,limit:50}, one per conversation shown. ShellListPage pages separately via fetchShellPage (useInfiniteList, ticked by shellSessionEventReceived). CLI src/ctl/shell_cmds.odin: `ham-ctl shell list` sends one request per invocation; run/log/kill use /shells/:id routes and never poll the list. Bridge shell_reconcile uses the bridge-scoped route. **Main duplicate driver: wsInvalidation.invalidateShellSession** invalidated ShellSessions:LIST immediately on each of the three frames per run (shell_session_started, resource_changed/shell_session "running", shell_session_exited), refetching every mounted key per frame in every tab. | Scoped + coalesced invalidation (next section). Each frame names only the cached list entries that can hold the session (per-entry tag ShellSessions:q:<url>) through the existing 150 ms queueInvalidation burst window; an unknown session or unreadable cache falls back to ShellSessions:LIST. The exact-URL key canonicalisation is kept as defensive only: no current caller passes ''/0 filters (AuxNewTabLauncher's `|| undefined` is already dropped by RTK's serializer), so it saves no measured request. |
| GET /cards/:id | Single caller ChatActionCard.tsx:37, which always passes {cardId,id} identically and skips fetching when initialCard exists. | Key by cardId || id kept as defensive only: no current caller issues both alias shapes, so no measured request is saved. Alias precedence, Card tags, mutation invalidation, decryption and initialCard skip are preserved. |
| GET /task-chains/:chain/tasks/:task | tasks.ts:fetchChainTaskDetail, ChainOverviewPanel AttentionTaskReviewCard and lazy detail consumers. CLI src/ctl/tasks.odin fetches once for show. | No change: equal chainId/taskId arguments, including reordered properties, already share one request. Preserve explicit refresh and full descriptions absent from list rows. |
| GET /agents/:id | agents.ts:fetchAgentIdentity; AgentChatPane, TaskChainOverview name resolution (skips known names), AgentDetail, AgentFormPage. | No change: equal agentId already deduplicates. Existing 600s unused retention, identity mutation tags, WS summaries and summary catalogue remain. Legacy fetchAgent is POST /agents/show, a different contract. |
| GET /bridge/task-chain-search/documents | src/bridge/task_chain_search_refresh.odin: 30s reconciliation plus startup/recovery triggers; existing in-flight mutex, revision cursor and paging. Hub taskchain_handlers.odin enriched even empty upsert lists. | Keep HTTP cadence, revision reconciliation and push triggers. Early return only from empty enrich_chain_list_items; normal handler envelope, revisions, has_more and tombstone loop remain. Nonempty enrichment uses a narrow conversation-project projection. |

The helper also serves grouped/per-project task-chain lists. Internal new-API consumers are content service -> conversation_project_index -> enrich_chain_list_items. Alternate/test repositories retain a fallback to the old listing. No wire consumer must change.

The projection retains owner scoping, exact COALESCE(NULLIF(last_message_at,''),updated_at,created_at) descending order, conversation_id descending tie break and LIMIT 200. Coordinator project precedence, chain fallback, missing/deleted-project behavior and archive filtering stay unchanged. The pre-existing >200 overflow limitation is deliberately preserved.

## GET /shells WS invalidation fan-out (attempt 2)

Hub frames per shell session (no event payload change): shell_session_started {session_id, kind, status, chain_id only when set} (shell_session_service.odin:836, _shell_session_started_event_json); resource_changed/shell_session from _shell_session_publish_changed {status, pid, port, run_seq, background, chain_id} for running/restarted/port_changed/backgrounded; shell_session_exited {session_id, status, exit_code[, error_code, bridge_id]}; inventory convergence resource_changed {status}; retention prune resource_changed with an empty resource_id.

Change (src/ui/api/wsInvalidation.ts invalidateShellSession, src/ui/api/endpoints/shells.ts):
- listShells additionally provides ShellSessions:q:<exact request URL>. Its existing chain and LIST tags are unchanged, so every mutation and other invalidation still reaches it.
- On a shell frame the handler gathers the session's scope facts from the frame (started: kind + chain_id, where absent means empty; change frame: chain_id) and from any cached row (getShellSession or any listShells page; scope columns are immutable). shellListMayContain excludes a cached list only when it provably cannot hold the session before or after the change: its bridge/chain/agent filter excludes the kind (mirror of SHELL_SESSION_SCOPE_RULES as applied by shell_session_list_by_owner_sqlite: bridge/chain lists hold server+shell, agent lists hold run), or a known scope value differs. Status, cursor and limit never exclude, and unfiltered lists (the status bar) always refetch.
- Tags go through the existing queueInvalidation 150 ms coalescer, so frames inside one window cost one refetch per list. The session detail tag ShellSession:<id> is still invalidated; the non-RTK shellSessionEventReceived tick stays immediate.
- Fallback to ShellSessions:LIST when the frame has no session id (prune) or the store cannot be read. resetApiState (logout, user switch, vault lock) already drops queued tags (paneDeferralResetMiddleware); reconnect resync is untouched. The REQ-SHELL-6 no-poller guarantee holds: no poller is added, and every list that can change still refetches.

Measured with tests/ui_shell_list_invalidation_test.ts: real handleUserWsEvent, real listShells endpoint and RTK middleware, and a fake hub applying the repo's scope/kind/status semantics. The mounted set is the status bar + AuxNewTabLauncher {chainId,status:live} + one conversation's run list. Every scenario also asserts that each mounted list equals the hub's current answer after the frames, so no list is skipped while stale. Before = the same test at 65419377 with DEDUP_BASELINE=1.

| Scenario (GET /shells per tab) | Before | After |
|---|---:|---:|
| Run by the open conversation's agent, frames spaced | 9 | 6 |
| Run by another agent, frames spaced | 9 | 4 |
| Run by own agent, all three frames in one burst | 6 | 3 |
| Chain server lifecycle, frames spaced | 9 | 6 |
| Exit of an uncached session (e.g. refused start) | 3 | 3 |

Limits: with only the status bar mounted (no conversation or chain view open) each frame still refetches that one list, so the per-run cost stays at 3. Savings scale with the number of scoped lists mounted and the share of runs from other agents. In a burst, the exit frame arrives before any list holds the row, so it conservatively refetches all lists. Patching lists from the frame payload was not used: the frames lack fields the rows render (finished_at, exit_code_set, pid, cmd), so patching would need an event payload change and a review of every consumer. These are local fixture request counts; the share of the production 350 GET /shells per 15 min that this removes is not measured.

## Cache, freshness and ETag decision

No server cache, persistent/general client cache or auth cache is added. Only two existing RTK keys are canonicalized. Existing mutation/WS tags, lifetimes, reconnect resync, vault locking and logout/reset isolation remain; no global response-sharing state is introduced. New entries/bytes limits or max-staleness policies therefore do not apply.

These routes currently have no ETag/304 contract; existing bootstrap/catalogue ETags belong to other resources and are untouched. A response hash after SQL would save bytes, not the measured statements/auth reads. A pre-query validator needs complete runtime/bridge/project/task-rollup invalidation coverage. The evidence supports existing-key and unused-SQL fixes first; no validator cache is introduced.

Auth-user lookup stays per request. A cache could hide revocation/role changes without immediate invalidation from every authority change; evidence does not establish that contract. The fixture's 19 VM steps per lookup do not justify changing auth semantics.

## Before/after evidence

Generated local fixtures only. Task-1 HTTP counts are modeled triggers; UI counts are actual stubbed fetch calls through real RTK middleware. No production latency, fsync or physical-I/O benefit is claimed.

| Scenario | Before | After |
|---|---:|---:|
| Two equivalent shell initiations (synthetic shape, no current caller; defensive) | 2 HTTP | 1 HTTP |
| Two card alias initiations (synthetic shape, no current caller; defensive) | 2 HTTP | 1 HTTP |
| Same task detail twice | 1 HTTP | 1 HTTP |
| Same agent identity twice (unchanged endpoint) | 1 HTTP | 1 HTTP |
| Eight distinct shell scopes/filters/pages | 8 HTTP | 8 HTTP |
| Empty enrichment x10: modeled HTTP | 10 | 10 |
| Empty enrichment x10: SELECT | 20 | 0 |
| Empty enrichment x10: VM | 642440 | 0 |
| Empty enrichment x10: conn_main acquisitions | 960 | 0 |
| Full conversation summaries vs project links x10: SELECT | 10 | 10 |
| Full summaries vs project links x10: VM | 487370 | 13950 |
| Both projections x10: cache page writes | 0 | 0 |

Mapping saves 473420 VM (~97.1%) per ten calls on 60 conversations/6000 messages. Full message-summary consumers remain unchanged. Narrow calls still have 630 conn_main acquisitions here; no acquisition reduction is claimed for the projection.

Task-1 baseline at cfe5316d: bash verify-baseline.sh, session sh_b7e2b01be55eb605cb783724fe28c171, exit 0. Original committed evidence: docs/call-reduction-baseline-results.md.
Client baseline: DEDUP_BASELINE=1 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_api_fetch_dedup_test.ts, session sh_2f06a478ef6dc9f91841de397e9545bc, exit 0. This initial replay used legacy POST fetchAgent for the unchanged-agent scenario; final regression explicitly uses GET fetchAgentIdentity. The shell/card key rows are synthetic call shapes and claim no production saving; the measured GET /shells saving is the WS fan-out table above.
After baseline: docs/api-fetch-dedup-baseline-after.txt, session sh_365d3f64c242ff69976ff99e5b2073ae, exit 0. Final verify replays it.

## Verification

~~~bash
bash verify-api-fetch-dedup.sh
~~~

The script fails on any error and uses unique binaries under $HOME/.cache/heimdall-tests:
- Standalone tests/api_fetch_dedup.odin with real migrations, SQLite, bridge auth and HTTP handler: projection owner/order/200-window equivalence, coordinator precedence and chain fallback, missing mapping, archived snapshot, fresh nonempty upsert, empty snapshot/delta, tombstones, vanished upsert and cursor/has_more pagination. Current application/json/no-ETag behavior asserted.
- Existing scoped test_enrich_chain_list_items_archive_filter.
- Task-1 real-procedure replay plus narrow projection measurement.
- npm run typecheck and production Vite build.
- REQ-SHELL-6 push test (tests/ui_shell_req6_push_test.sh: real bundled handler, flushes the burst window) and the GET /shells lifecycle count test.
- 39 UI tests: new request replay and existing refresh request-reduction, integration and performance suites. Covers distinct filters/pages, alias precedence, one refetch for Card invalidation, auth-boundary reset, shell-prune invalidation and reconnect.

Intermediate errors were test-construction fixes: window shim, Odin syntax/signatures and explicit mixed_work fixture kind. One full verification run's Vite build segfaulted (139) on Node v26.4.0 after existing Rollup warnings; immediate npm exec vite -- build --logLevel warn retry passed (sh_1941a1a8a17cc543a20a949a0721886a). No dependency/config workaround was added. Existing missing VITE login/logout variables, Toast circular-export and chunk warnings remain.

Independent source/evidence review is required by the task workflow; approval is not claimed here.
