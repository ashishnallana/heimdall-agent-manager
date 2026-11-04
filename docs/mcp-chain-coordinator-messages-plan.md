# MCP messages to task-chain coordinators

An authenticated MCP caller will be able to send text to the current coordinator of an owned task chain. The message will appear as a normal user message in that coordinator's conversation and use normal agent notification/restart behavior. This is a proposal for explicit user approval, not an implementation.

## Scope and approval

Planning task: task_18e43a7bdbe98a20. Target repository: /var/home/tanmay/heimdall-agent-manager, inspected at 5c0cce59b1bb44b6434cac6722f7e9ba39a3a120. The deliverable is committed in the assigned task worktree.

This feature is additional to task_18e43a5ae97fa917 (requiring a durable coordinator agent ID when creating a chain through MCP). That task retains its own acceptance criteria and review. This proposal does not change chain creation, assign a coordinator, approve tasks, or grant general chat access. Implementation starts only after the user explicitly approves this plan through the existing task review UI or an explicit instruction recorded on the task.

## Proposed tool contract

Advertise `chains.message` with exactly three required inputs:

| Input | Validation |
| --- | --- |
| `chain_id` | Existing chain ID grammar and 256-character bound from `control_id_ok`. |
| `body` | UTF-8 text; reject missing, wrong type, empty/whitespace-only, or more than 20,000 UTF-8 bytes. Preserve valid text as supplied. |
| `request_id` | Stable nonempty ID using the existing mutation request-ID grammar; caller reuses it with identical arguments after an ambiguous result. |

Reject unknown fields. Caller cannot specify owner, sender, conversation, coordinator instance, message direction, attachments, question controls, or review actions. Return `chain_id`, `coordinator_agent_instance_id`, `conversation_id`, `message_id`, and `status: "accepted"`. Acceptance means durable chat persistence, not coordinator execution or readiness. Do not echo the plaintext message.

Add a dedicated `mcp:chains:message` consent capability, with wording explaining that messages appear as the connected user and may wake the coordinator on an owned machine. Existing grants do not gain this ability silently. Keep it independent of task-write permission.

## Authorization and routing

1. Authenticate using the existing MCP bearer/delegation path in `src/hub/transport/http/mcp_control_handlers.odin`. Require the new capability for both tools/list visibility and tools/call execution.
2. Read the target using `tc.get_chain_for_read` under `mcp.control_auth(view.owner)`. The owner comes only from the validated access view. Return the same not-found error for missing and foreign chains.
3. Resolve the canonical coordinator membership, not the derived `task_chains.coordinator_agent_instance_id` mirror. `src/hub/service/taskchain/taskchain_service.odin:coordinator_primary_instance` selects the earliest-created coordinator membership. Preserve that selection rule; add a checked resolver returning repository errors distinctly, since the current helper collapses database errors into an empty result.
4. Validate the selected instance belongs to the authenticated owner, and resolve its existing conversation via `content.get_conversation_by_instance`. Validate that conversation owner and instance binding independently. Do not create a replacement coordinator or guess from durable agent defaults, another chain, or the mirror column. An instance's existing conversation need not carry this chain's ID, since one coordinator may coordinate multiple chains.
5. Revalidate grant/epoch/scope using the existing write-authorization helper immediately before persistence, and re-read canonical coordinator membership in the same unit of work. If routing changed during encryption, resolve again under the same owner checks. A replay of an already committed request returns its original target/message rather than sending to a new coordinator.

## Encryption, persistence, display, and delivery

Seal `body` before storage using both existing hosted and approved-device/bridge transformation modes. Add a narrowly scoped `seal_message` operation bound to `chains.message` and the new capability. Validate the returned vault envelope against the authenticated vault ID/current epoch as in `mcp_task_envelope_ok`. No plaintext fallback on locked device, unavailable key, mismatched epoch, revocation, or transform failure. Clear transient body/digest input buffers using the existing mutation conventions; no body in logs, receipts, audit metadata, or tool results.

Use the content service's user-message semantics: `direction=user_to_agent`, `message_type=text`, body equal to the sealed envelope, normal owner/instance binding and conversation preview timestamps. Preserve existing sender-field conventions: the current user-message implementation uses the conversation's agent IDs, while direction determines user rendering. Optional metadata may identify MCP provenance without changing the displayed role or storing message text.

Refactor `src/hub/service/content/content_service.odin:send_message` narrowly into shared persistence and post-commit delivery helpers so both normal chat and this endpoint retain validation and side effects. The current function notifies immediately and `attention_notify.odin:save_message` also signals attention; do not invoke those side effects inside an uncommitted MCP transaction. Persist message, conversation update, and idempotency receipt atomically with errors checked. Reuse `src/hub/repository/sqlite/mcp_mutations.odin` receipts, keyed by owner/grant/tool/request ID and the canonical request digest; identical retry returns the original result, different content returns `idempotency_conflict`. Store no plaintext in receipts.

After commit, call shared normal delivery helpers:
- Publish the owner-scoped chat-created event following `publish_user_message_created` in `src/hub/transport/http/content_handlers.odin`. Existing `src/ui/utils/vaultChats.ts` decrypts body/preview, and existing chat UI displays the user direction. No special MCP-only bubble is required.
- Preserve attention updates and activity/title nudge behavior.
- Apply the existing configuration guard and restart policy from `restart_stopped_conversation_instance` for stopped/failed/unreachable instances, then send the normal `notify_agent_message` notice with sender `user`. Share the policy rather than adding terminal injection. The Bridge's `src/bridge/hub_runtime_client.odin` already handles this notice.
- Keep runtime/Bridge operations outside the database transaction. If restart or notice fails after persistence, the result remains accepted and must not trigger duplicate persistence. Report a bounded `delivery_warning` such as `bridge_offline` with the saved IDs, leaving the message readable through normal chat fetch. Do not promise a new durable notification queue or automatic replay; those are outside this scope.

## Implementation file map

All paths below are relative to the target repository root.

| Area | Existing files and proposed changes |
| --- | --- |
| MCP schema/dispatch | `src/hub/transport/http/mcp_tools.json`, `mcp_control_handlers.odin`; add schema, strict parser/dispatch, capability-gated catalog entry, and update initialize instructions currently saying “No messaging”. Add focused `mcp_chain_messages.odin` transport code. |
| Service contract/application wiring | `src/hub/service/mcp/control.odin`, `src/hub/app/wiring.odin`; add typed command/callback. Add `src/hub/app/mcp_chain_messages.odin` for write reauthorization, routing, transaction/receipt, and post-commit effects. Follow `mcp_task_mutations.odin`. |
| Coordinator/content | `src/hub/service/taskchain/taskchain_service.odin` for checked canonical resolver; `src/hub/service/content/content_service.odin`, `attention_notify.odin`, and `src/hub/transport/http/content_handlers.odin` for shared transactional persistence and normal delivery helpers. |
| Consent/scopes | `src/lib/vault/control_scopes.odin`, `src/hub/service/mcp/capabilities.odin`, `src/ui/utils/mcpCapabilities.ts`; add explicit messaging permission and consent wording. |
| Encryption parity | `src/lib/vault/control_job.odin`, `control_job_scope.odin`, `src/hub/service/mcp/control.odin`, and `src/ui/utils/mcpWorker.ts`; add and validate the narrow sealing operation across hosted/device/Bridge paths. |
| Tests/docs | Extend adjacent MCP HTTP/app, content-service, scope/transform and UI worker tests; document tool contract and consent in the existing MCP documentation. Reuse receipt schema; no database migration is anticipated. |

## Errors

| Code | Caller action |
| --- | --- |
| `invalid_arguments` | Supply valid chain ID, stable request ID, and nonblank text within the limit; remove unknown inputs. |
| `invalid_token` / missing capability | Reconnect/re-consent with messaging permission. Preserve existing authentication versus tool-error conventions. |
| `not_found` | Select a chain accessible to this account; identical result for nonexistent/foreign chain. |
| `coordinator_missing` | Assign a coordinator to this owned chain, then retry. |
| `coordinator_unavailable` | Repair missing/inactive coordinator instance or missing conversation; no silent fallback. |
| `decryption_unavailable` | Unlock/approve an authorized sealing device or reconnect the hosted grant; nothing stored. |
| `idempotency_conflict` | Reuse the request ID only for the original arguments, or supply a new ID for a new message. |
| `request_failed` | Transient/internal failure; retry identical request ID. Never disguise a database error as missing coordinator. |

Runtime failure after commit is an accepted result with a delivery warning, not an error implying that no message was stored.

## Regression coverage and verification

- Successful hosted and device-mode sends: exactly one sealed durable message in the resolved coordinator conversation, correct user direction, owner-only event, decryptable body/preview, and normal user notification.
- Live coordinator notification and stopped coordinator restart; offline/restart failure retains the saved message and reports delivery warning. No network/attention/UI effects before commit; commit failure leaves no message or receipt.
- Foreign/missing chain, foreign instance/conversation, absent/stale coordinator membership, and stale mirror: deny or select canonical membership as appropriate, with no storage/restart/notification on denial.
- Scope denied in listing and direct calls; read/task-write-only grants cannot send. Revoked/expired credentials and changed epoch between transform and commit cannot persist.
- Invalid/missing/wrong-type/unknown/oversized/whitespace message inputs; UTF-8 byte boundary cases; hosted/device worker scope binding and wrong-vault envelope rejection.
- Identical retries including concurrent requests and post-timeout retries return the original message ID once; changed arguments conflict; coordinator reassignment does not redirect an already committed replay.
- Existing browser user-chat send, agent-to-agent messaging, attention updates and MCP task mutations remain unchanged by helper extraction.
- Existing MCP coordinator-creation requirement tests from task_18e43a5ae97fa917 remain separate.

Implementation checks will use Nix Odin, `-collection:odin_test=src`, and unique test outputs under `$HOME/.cache/heimdall-tests`. Run focused new tests, then affected package suites (`src/lib/vault`, `src/hub/service/mcp`, `src/hub/service/content`, `src/hub/service/taskchain`, `src/hub/app`, `src/hub/transport/http`) and affected UI worker/consent tests from the existing npm scripts. Exact filters and results belong in the implementation handoff. Planning-only verification consists of source-reference checks and `git diff --check`; no application code is changed or runtime tests claimed here.
