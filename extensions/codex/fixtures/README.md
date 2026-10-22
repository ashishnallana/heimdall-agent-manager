# Native release fixture procedure

Use only a disposable scratch home/workspace and synthetic prompts. The collector omits prompt/transcript text, writes private files, and caps each callback at 1 MiB and its log at 16 MiB. Raw captures remain outside git. The committed corpus replaces native IDs consistently and uses `/workspace` paths; encrypted child instructions are redacted.

```sh
python3 extensions/codex/fixtures/prepare.py init "$HOME/.cache/heimdall-codex-fixtures-new"
```

This creates no credentials. Authenticate the isolated home normally. If specifically authorized, `--copy-native-auth` permits a private native credential copy; never print its contents or commit it. This task received that narrow coordinator authorization. Original auth/config/hooks checksums are recorded privately.

Run the pinned binary with isolated `HOME` and `CODEX_HOME`, a synthetic workspace, and no bypass flags. Trust the scratch folder and inspect/trust collector hooks through the native UI. Record startup; submit synthetic prompts for successful/nonzero/polled shell calls; patch create/update/move/delete and failed operations; child tool/lifecycle and concurrent child permission requests. Exercise native clear, compact, fork, resume, and interrupt. Never manufacture missing callbacks.

Install the package into the isolated home using the parent README commands. Check inventory without granting trust:

```sh
CODEX_BIN=/absolute/path/to/codex python3 extensions/codex/fixtures/probe_plugin.py \
  "$HOME/.cache/heimdall-codex-fixtures-new" \
  /absolute/path/to/repo/extensions/.agents/plugins/marketplace.json
```

The inventory tool only calls initialization, `plugin/read`, and `hooks/list`; it does not implement an agent transport or run a model.

For live native-to-bridge validation, build the bridge test binary and ctl under the normal Nix development environment. Run only `test_codex_live_bridge_listener_when_explicitly_configured` with `HEIMDALL_CODEX_LIVE_PORT=45377`. The loopback test listener uses public synthetic tokens `fixture-one`/`fixture-two`, actual bridge reducers, no Hub forwarding, and no production configuration. Start two native sessions with the built ctl as `HEIMDALL_CTL_BIN`, `HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:45377`, and distinct fixture tokens. Native hook trust is still required.

```sh
python3 extensions/codex/fixtures/fixture_rpc.py inspect fixture-one --save /private/evidence-one.json
python3 extensions/codex/fixtures/fixture_rpc.py allow fixture-one
python3 extensions/codex/fixtures/fixture_rpc.py deny fixture-two
python3 extensions/codex/fixtures/fixture_rpc.py finish fixture-one
```

The last command ends the opt-in listener after evidence collection; it requires both fixture instances to have emitted Codex signals. Normal verification leaves the listener disabled and always replays the native callback corpus through the real bridge ingest/identity path.

Stop all scratch Codex processes before cleanup:

```sh
python3 extensions/codex/fixtures/prepare.py cleanup "$HOME/.cache/heimdall-codex-fixtures-new"
```

This removes the temporary auth copy and verifies the original store checksums. Sanitize and review any additional fixture before copying it into git. Never represent local native-to-bridge and separate hub ingestion tests as a continuous deployed full-stack E2E.
