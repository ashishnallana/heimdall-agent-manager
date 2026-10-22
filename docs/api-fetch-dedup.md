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
| GET /shells | listShells in src/ui/api/endpoints/shells.ts: ShellLaunchPanel + RunningShellSelectorModal both use status=live,limit=200; useConversationRuns in ShellRunIndicator uses agentInstanceId,limit=50. ShellListPage uses separate paged fetchShellPage. CLI src/ctl/shell_cmds.odin:ctl_shell_list sends one request per invocation; bridge shell_reconcile uses the different bridge-scoped route. | Canonicalize RTK key to the exact emitted URL. Replay proves {chainId} and {chainId,cursor:'',limit:0,status:undefined} generated identical requests with different keys. Preserve every emitted scope/filter/page/cursor. Existing identical component calls already deduplicated; production duplicate fraction unknown. No cross-process CLI cache or timer changes. |
| GET /cards/:id | ChatActionCard passes both id and cardId and skips fetching when initialCard exists. getCard also accepts either alias. | Key by cardId || id. Preserve alias precedence, Card tags, mutation invalidation, decryption and initialCard skip. Two alias initiations previously made two requests; now one. This demonstrates an endpoint case, not the production incidence of overlapping components. |
| GET /task-chains/:chain/tasks/:task | tasks.ts:fetchChainTaskDetail, ChainOverviewPanel AttentionTaskReviewCard and lazy detail consumers. CLI src/ctl/tasks.odin fetches once for show. | No change: equal chainId/taskId arguments, including reordered properties, already share one request. Preserve explicit refresh and full descriptions absent from list rows. |
| GET /agents/:id | agents.ts:fetchAgentIdentity; AgentChatPane, TaskChainOverview name resolution (skips known names), AgentDetail, AgentFormPage. | No change: equal agentId already deduplicates. Existing 600s unused retention, identity mutation tags, WS summaries and summary catalogue remain. Legacy fetchAgent is POST /agents/show, a different contract. |
| GET /bridge/task-chain-search/documents | src/bridge/task_chain_search_refresh.odin: 30s reconciliation plus startup/recovery triggers; existing in-flight mutex, revision cursor and paging. Hub taskchain_handlers.odin enriched even empty upsert lists. | Keep HTTP cadence, revision reconciliation and push triggers. Early return only from empty enrich_chain_list_items; normal handler envelope, revisions, has_more and tombstone loop remain. Nonempty enrichment uses a narrow conversation-project projection. |

The helper also serves grouped/per-project task-chain lists. Internal new-API consumers are content service -> conversation_project_index -> enrich_chain_list_items. Alternate/test repositories retain a fallback to the old listing. No wire consumer must change.

The projection retains owner scoping, exact COALESCE(NULLIF(last_message_at,''),updated_at,created_at) descending order, conversation_id descending tie break and LIMIT 200. Coordinator project precedence, chain fallback, missing/deleted-project behavior and archive filtering stay unchanged. The pre-existing >200 overflow limitation is deliberately preserved.

## Cache, freshness and ETag decision

No server cache, persistent/general client cache or auth cache is added. Only two existing RTK keys are canonicalized. Existing mutation/WS tags, lifetimes, reconnect resync, vault locking and logout/reset isolation remain; no global response-sharing state is introduced. New entries/bytes limits or max-staleness policies therefore do not apply.

These routes currently have no ETag/304 contract; existing bootstrap/catalogue ETags belong to other resources and are untouched. A response hash after SQL would save bytes, not the measured statements/auth reads. A pre-query validator needs complete runtime/bridge/project/task-rollup invalidation coverage. The evidence supports existing-key and unused-SQL fixes first; no validator cache is introduced.

Auth-user lookup stays per request. A cache could hide revocation/role changes without immediate invalidation from every authority change; evidence does not establish that contract. The fixture's 19 VM steps per lookup do not justify changing auth semantics.

## Before/after evidence

Generated local fixtures only. Task-1 HTTP counts are modeled triggers; UI counts are actual stubbed fetch calls through real RTK middleware. No production latency, fsync or physical-I/O benefit is claimed.

| Scenario | Before | After |
|---|---:|---:|
| Two equivalent shell initiations | 2 HTTP | 1 HTTP |
| Two card alias initiations | 2 HTTP | 1 HTTP |
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
Client baseline: DEDUP_BASELINE=1 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_api_fetch_dedup_test.ts, session sh_2f06a478ef6dc9f91841de397e9545bc, exit 0. This initial replay used legacy POST fetchAgent for the unchanged-agent scenario; final regression explicitly uses GET fetchAgentIdentity. Only shell/card scenarios claim new HTTP savings.
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
- 39 UI tests: new request replay and existing refresh request-reduction, integration and performance suites. Covers distinct filters/pages, alias precedence, one refetch for Card invalidation, auth-boundary reset, shell-prune invalidation and reconnect.

Intermediate errors were test-construction fixes: window shim, Odin syntax/signatures and explicit mixed_work fixture kind. One full verification run's Vite build segfaulted (139) on Node v26.4.0 after existing Rollup warnings; immediate npm exec vite -- build --logLevel warn retry passed (sh_1941a1a8a17cc543a20a949a0721886a). No dependency/config workaround was added. Existing missing VITE login/logout variables, Toast circular-export and chunk warnings remain.

Independent source/evidence review is required by the task workflow; approval is not claimed here.
