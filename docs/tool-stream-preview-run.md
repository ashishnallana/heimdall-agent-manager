# Isolated tool stream preview

Verified 2026-10-23. Services are intentionally left running for hands-on review.

Open the Hub-returned URL exactly as recorded:

<https://heimdall-preview.mundus.in/p/sh_075207f8d9ec3e0e4267ec38e8bc25b9/>

This is an isolated local Hub, not production data. UI candidate
`e8a2fea692c6f3838b3b4eda40e8cb78c276d373` was TypeScript/build checked by S2;
formal S2 review was pending when previewed. Backend source is approved
`263cdff81db41e067d00711a6aa99fd58a639bf0`. The candidate's backend source trees
are identical to that commit. Preview plumbing changes are on top of the UI candidate.

## Try it

1. Open the preview. If the preview origin requires authentication, open it in a
   new tab and sign in normally once.
2. If the local vault asks to pair this browser, send the displayed pairing code
   to the coordinator. The isolated seed approver can approve it without sharing
   private keys. Do not import production vault credentials.
3. Open chain **Tool stream hands-on preview**, then agent **Stream smoke**
   (definition **Tool stream preview smoke**).
4. Ask: `Run a native shell command printf tool-stream-hands-on; sleep 10, then report completion.`
5. Watch the tool row in the conversation scroll tail. It should show the tool
   name, command summary, running time, and agent badge; completion clears the
   active row after the transient completion display. The agent uses real Codex.

The coordinator can approve the actual browser code using this checkout:

```bash
env HEIMDALL_LOCAL_STATE_ROOT=/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf \
  bash scripts/local-hub.sh approve-device --name tool-stream-18e13baf --code ACTUAL-CODE
```

## Owned runtime

| Component | Port / ID |
| --- | --- |
| Hub | 18791 |
| Dev proxy | 18790 |
| Reserved local UI port (no Vite dev server) | 15791 |
| Isolated Bridge / local agent endpoint | 49791 / 49792 |
| Preview production bundle server | 45291 |
| Preview managed session | `sh_075207f8d9ec3e0e4267ec38e8bc25b9` |
| Enrolled isolated Bridge | `brg_18e13bea9b4f1082` |
| Local chain | `chain_18e13c02c0bb6b4f` |
| Native Codex instance | `inst_18e13c02c10ba3be` |
| Local conversation | `chat_18e13c02c10bad5e` |

Worktree: `/home/tanmay/hamwt/tool-stream-preview`, branch `tool-stream-preview`.
Private isolated state root:
`/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf`.
Instance name for both launchers: `tool-stream-18e13baf`.
Hub/Bridge processes are owned by launcher PID/start-time records inside that root;
they are detached services, not long-lived managed shell sessions. Their tracked
launcher runs were `sh_e76f61c5bc5d3372ec2a372a620d5dff` (Hub) and
`sh_4bbe119fb13f46bc29264e686c71bd45` (Bridge), both exit 0.

The supported headless seed approver/device enrollment was used. Enrollment's
service-restart no-op shims were preserved. No installed services, production
configuration, provider login files, or production credentials were changed/copied.

Both Claude 2.1.295 and Codex 0.162.0 were discovered and enabled for this isolated
Bridge. Both Heimdall plugins report present version 0.1.0. Installed Claude and
Codex package directories compare byte-for-byte equal to this checkout's
`extensions/claude-code` and `extensions/codex`; no plugin update was needed.
The real native smoke used Codex. Claude native execution was not exercised.

## Build and verification evidence

Fresh Hub/Bridge/CLI builds ran with `nix develop` in tracked session
`sh_61e4724e7e68b5a0a4bcf0788cb14636` (exit 0); no unproven cached backend was reused.
The dev proxy was built fresh from the same source. There is no `src/wrapper` in
this checkout: the current Bridge embeds that runtime. Coordinator confirmed
using the managed `ham-pty-host` instead of building an obsolete wrapper.

Binary directory: `/home/tanmay/.cache/heimdall-tests/tool-stream-preview-bin`.
Its `source-head` records the UI candidate. Existing baked-in version metadata
reports an older default commit; provenance is the actual source/build command
and hashes below, not that default version string.

| Binary | SHA-256 |
| --- | --- |
| ham-hub | `2f8d6cf1b767fb3f5c2c36cc5ab9d34e1521adfd19e9198d9f7085f74edaac8c` |
| ham-bridge | `fe681b107aea219065c1c561bdb38567e336613ee5df1ffa0a11acfacaf723f4` |
| ham-ctl | `f33db303398908cdd61ad830654503e3593c84b43d23030bc8e8a2419ebb36bc` |
| ham-dev-proxy | `b5465ca14169a55ceee9d56824ef4fe7499a18fca6f1a14ee5f4ce90ec5668f1` |
| managed ham-pty-host | `f92af66b96b850b82605f1b7e9d2bcbff1f19249ec03f9440c29a521b9171d5a` |

`npm ci --legacy-peer-deps` and
`VITE_API_BASE=. npx vite build --outDir dist-tool-stream-preview --emptyOutDir`
passed. UI candidate `npm run build` (TypeScript included) passed in S2.
Preview launcher run `sh_9f56e13d10d23c4796e3a3a6c22cf84c` passed prefix index,
hashed assets, authenticated `/me`, and entry guard checks.

```bash
bash /home/tanmay/hamwt/tool-stream-preview/verify-tool-stream-preview.sh
# Optional explicit native provider command, beyond the repeatable managed shell:
bash /home/tanmay/hamwt/tool-stream-preview/verify-tool-stream-preview.sh --native
```

Native smoke session `sh_a4d67282327ae7b2f36bb3fb9a4cb3e9` passed 14 checks:
HTTP relay health/identity/isolated enrolled Bridge, SPA and assets, dedicated
ticket-authenticated WS baseline and ping/pong, a real managed shell active
summary, second viewer active baseline, measured terminal duration and removal,
and actual native Codex tool active/completed frames. Native Bash summary was
`printf tool-stream-native-smoke; sleep 6`, completed duration **6080 ms**.
Extension status at capture: **48 accepted, 0 dropped**.

Exact native evidence, including actual stream frames, is private at
`<state-root>/native-smoke-evidence.json`; repeatable verification writes
`<state-root>/live-smoke-evidence.json` separately. Neither file contains tokens
or keyrings. Native fixture setup records only public IDs in `<state-root>/smoke.json`.

**Verification boundary:** HTTP checks traverse the real managed machine-to-machine
`/proxy` relay. That relay strips Upgrade headers, so its WebSocket request became
ordinary GET/404. WS checks instead traverse the actual browser-facing preview
server, dev proxy, and isolated Hub. Both ticket and trusted-proxy authentication
passed there. The outer public Authentik/browser WS route has **not** been observed
by this worker; user hands-on testing or S3 must cover it. No authentication was
bypassed and no production relay code was changed.

## Scoped plumbing changes

- `ui-preview.sh` parses the JSON envelope even when CLI output includes a trailing
  `Preview:` line and prints the returned `preview_url` verbatim.
- It replaces only the session recorded in this checkout, preserving other previews
  sharing a chain/label.
- `preview-server.mjs` logs URL paths without ticket query values. It forwards
  upgrade head bytes to the correct peer after the upgrade.
- Fixture setup and repeatable live smoke are task-specific scripts, not production
  deployment tools. The setup script is one-time for this already-seeded instance.

## Cleanup — supplied only; do not execute during review

Use the managed CLI from the worker runtime directory to stop only this preview:

```bash
./.heimdall/bin/ham-ctl shell kill sh_075207f8d9ec3e0e4267ec38e8bc25b9
```

Then, from this preview worktree, stop only these launcher-owned services:

```bash
env HEIMDALL_LOCAL_STATE_ROOT=/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf \
  bash scripts/local-bridge.sh stop --name tool-stream-18e13baf
env HEIMDALL_LOCAL_STATE_ROOT=/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf \
  bash scripts/local-hub.sh stop --name tool-stream-18e13baf
```

Stop the native instance through the isolated UI before stopping the Bridge.
Do not stop other sessions, remove production state, or delete this private state
root while the user is testing. The earlier temporary origin-only session
`sh_6873ece86a0d3f5f64a301b1e4cc04f7` and superseded preview
`sh_c890a2ffc51056570f34ac7e5ee5408b` were already stopped by this worker.
