# Codex image hook completion evidence

## Native reproduction (2026-10-24)

Codex CLI 0.162.0 with gpt-6.1-sol ran in a disposable HOME/CODEX_HOME and
workspace using the repository collector. Its 12 collector hooks were reviewed
and trusted through the normal native /hooks UI. No production hooks or agent
configuration changed. Raw synthetic captures remain private under
~/.cache/heimdall-codex-image-fixtures-task18e17ce9; credentials are not fixtures.
The native process exited, prepare.py cleanup removed the temporary auth copy,
and original auth/config/hooks checksums were unchanged.

The committed image_callbacks.json is the actual image/Stop subset, with
consistent session/turn/call IDs and /workspace paths. The large image data URL
is replaced with an explicit omission marker. Small image bytes describe only
a synthetic 16x16 red PNG. Large regression payloads are generated in tests.

| Native operation | Observed callback lifecycle |
| --- | --- |
| Invalid PNG | PreToolUse, no PostToolUse; eventual Stop |
| Missing PNG | PreToolUse, no PostToolUse; eventual Stop |
| Valid 16x16 PNG | PreToolUse and PostToolUse share exec-* tool_use_id |
| Valid 768x768 random RGB PNG (1,770,846 bytes) | Paired PostToolUse is 2,361,718 bytes |

The successful response is an array containing
{type:input_image,image_url:data:application/octet-stream;base64,...,detail:high}.
The image completion in the affected agent's read-only native rollout independently
uses item_completed/ImageView with the same exec-* identity. Its two PNG files
are 2,416,681 and 2,823,112 bytes. We did not capture that agent's original hooks;
the isolated native run proves the corresponding callback schema and size defect.

## Defect and correction

The mapper previously rejected the entire callback above 1 MiB before clipping
strings. Its successful PreToolUse therefore remained active despite a matching
native completion. The new native-envelope bound matches the CLI stdin reader's
16 MiB cap. Output event/batch caps remain enforced independently. Image responses
are omitted before cloning/clipping, so no image URL or bytes enter canonical
activity events, the bridge outbox, or live snapshots. Tool identity is emitted
even when input and response metadata are both absent.

This intentionally permits bounded parsing of larger Codex callback envelopes.
It does not stream unlimited image data: an envelope above 16 MiB is still
rejected and cannot deliver completion through this hook adapter. Generated tests
cover exactly the cap, one byte above it, a 2.4 MB image response, and absent
input/response metadata. A callback lost to the cap or transport is not recovered
by an age limit or later assistant prose.

## Failure limitation and validation

This native release emitted no PostToolUse for missing/invalid images. Such calls
still lack an authoritative terminal hook and can remain active. Stop is activity
only: it is not treated as success or failure for outstanding calls. Fixing this
separate provider-signal gap requires authoritative recovery evidence; this change
does not fabricate a failure payload or claim to repair it.

Both new mapper tests failed on the original implementation (Too_Large and image
payload leakage) and passed after the fix. The bridge regression sends generated
large-image native callbacks through the actual mapper and issued-instance ingest,
then checks live removal, final duration, concurrent child/instance isolation,
duplicate completion, empty-completion baseline, and reset isolation. Existing
tracker tests retain failed-outcome, shell, concurrency, and lifecycle coverage.

The task verification runs all 10 Codex mapper/patch tests, all 16 tracker tests,
five scoped bridge tests, the three live-tool Node suites, a production ctl build,
and npm run build. No UI lifecycle code changes; existing minimum visibility and
collapse behavior are exercised by the unchanged UI regressions.
