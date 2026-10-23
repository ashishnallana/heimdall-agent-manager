# Publication merge reconciliation

This merges reviewed tool integration 723b9a6cb8b9fce4d6fd8270f867d326a1783903
into fetched origin/main 1dbf9ac2f22c654c26571b77804d138518ffc312.
Both histories remain parents of the merge. The actual recursive merge had two
bases: fc983f52ef8210f9257dd698f8814a43acbd9a67 and
c7f5f07ff078f2adb1183fd92a6faed24a36fce3.

## Conflict resolutions

- package.json: retain upstream test script, including the new agent stream
  reconnect suite. The only script conflict was that added suite. Dependencies
  and package metadata retain upstream values. The package metadata version is
  0.3.3 on both parents; the actual release version remains 0.4.30 in
  src/contracts/protocol.odin and flake.nix. No invented package version change.
- src/ctl/args.odin: retain upstream spelling/order. Both sides contain precisely
  the same value-taking flag set, including --questions-file; their ordering
  around --on-behalf-of differs. The rest of the CLI auto-merges.
- src/hub/repository/iface/content_repo.odin: retain upstream layout to keep
  exactly one content_latest_user_visible_message helper after the project-link
  fallback. The helper body is identical on both parents; both interfaces remain.
- src/ui/components/chat/ChatMessageList.tsx: retain upstream's explanatory
  tool marker comment. The functional merged file is identical to reviewed S3,
  so multi-question rendering and live scroll-tail coexist.

## Semantic inspection and compatibility

Against S3, production source changes are only the newer upstream terminal
reconnect/retry/target-reset components, shell no-viewer resync guard, release
version, and equivalent args/helper ordering plus the comment above. In
particular AgentChatPane.tsx, wsInvalidation.ts, the content/chat API code and
tool transport implementation are unchanged from S3. The dedicated summary
socket, fanout/subscriptions, listener cadence/refresh, UI receipt expiry and
watchdog, one-line tool tail and saved Activity-tab migration are preserved.
The merged AGENTS.md retains upstream composer retry debug IDs and incorporates
the reviewed timeline removal/live-tool debug IDs without dropping guidance.

Remove one trailing empty line in src/ui/api/userStreamUrl.ts, inherited from
S3, so git diff --check passes for the final merge.

## Verification

Run bash /home/tanmay/hamwt/tool-stream-main-merge/verify-tool-stream-main-merge.sh.
It records exact-head evidence under ~/.cache/heimdall-tests/tool-stream-main-merge-*:
scoped tool-stream, multi-question contract/CLI/repository/HTTP and shell writer
Odin tests; live-tool/freshness/DOM/aux hydration, multi-question, terminal retry
and attention UI regressions; Hub/Bridge/CLI, TypeScript/Vite/Electron builds;
ancestry, clean tree, whitespace and conflict-marker checks.

The captured-frame consumer reuses actual 723b9a6c evidence from
/home/tanmay/.cache/heimdall-tests/tool-stream-integrate-reeSgF/manifest.json
after byte-compatible transport source checks. This is a fresh consumer check,
not a new 60-second end-to-end run. Prior S3 evidence covers 60 Odin / 101 UI /
40 real-stack assertions and 27 captured frames. See live-tools-integration.md
for measurements, source hashes and native/browser limitations.

No preview processes are restarted, stopped or redeployed, no shared checkout
source is edited, and this worker does not push. Independent review is code
and evidence only, with publication left to the coordinator after review.
