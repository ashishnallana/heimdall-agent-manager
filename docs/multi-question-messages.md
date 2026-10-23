# Multi-question messages (version 1)

Send one explicit form with all questions. Selecting an option does not submit it.
Each question permits custom text **instead of** selecting options. All questions
must be answered in one explicit submit. Keep drafts after any failed request.

## Agent CLI

`questions.json` is a UTF-8 JSON object:

```json
{
  "version": 1,
  "questions": [
    {
      "id": "target",
      "text": "Where should the release go?",
      "options": [
        {"id": "staging", "label": "Staging"},
        {"id": "production", "label": "Production"}
      ]
    },
    {
      "id": "checks",
      "text": "Which checks should run?",
      "selection_mode": "multiple",
      "options": [
        {"id": "smoke", "label": "Smoke tests"},
        {"id": "integration", "label": "Integration tests"}
      ]
    }
  ]
}
```

```bash
ham-ctl chat send --to user --body 'Choose the release settings.' --questions-file questions.json
```

The CLI validates the file before sending and encrypts `body`, question `text`,
and option `label` with the existing vault keyring. Encryption fails closed.
`--questions-file` is user-only and cannot be combined with flat `--options`
(including its aliases). `--actions` may accompany the form. Existing text,
flat options, and actions retain their original paths.

IDs are stable, nonempty, at most 64 ASCII letters, digits, `_`, or `-`.
Question IDs are unique in the group; option IDs are unique within their question.
There are 1–12 questions, each with 1–12 options. `selection_mode` defaults to
`single`; only `single` and `multiple` are valid. Every question always supports
the UI's custom-text alternative; no additional custom label is sent.
Plain question text is limited to 8192 bytes and labels to 2048 bytes.
The JSON group and complete answer submission are each limited to 256 KiB.
Unknown fields are rejected inside these versioned objects.

## Wire message and read model

The existing `agent.chat.send` envelope routes unchanged through the Bridge.
The CLI sends this payload (angle-bracket text denotes vault v2 armor):

```json
{
  "to": "user",
  "body": "<vault v2 encrypted body>",
  "message_type": "multi_question",
  "metadata": {
    "multi_question": {
      "version": 1,
      "questions": [
        {
          "id": "target",
          "text": "<vault v2 encrypted question>",
          "selection_mode": "single",
          "options": [{"id": "staging", "label": "<vault v2 encrypted label>"}]
        }
      ]
    },
    "action_ids": ["crd_optional"]
  }
}
```

REST message reads and the agent inbox retain the existing `message_type`,
`metadata`, and `metadata_json` fields. For source messages, an additional
`question_answer` field is `null` until answered, then:

```json
{"answer_message_id":"msg_answer_msg_source","answered_at":"2026-10-22T13:00:00Z"}
```

That state is projected from the durable answer row, persists across reloads and
devices, and leaves the source body and original questions untouched. The CLI
decrypts `text`, `label`, and `custom_text` in structured JSON, in addition to
existing private fields. A locked client must keep the controls disabled and use
its existing encrypted-content fallback. The Hub validates envelope shape and
structural IDs without possessing text keys.

Grouped question messages and legacy messages with `metadata.options` also expose
`is_latest_message` (boolean), computed against the entire durable conversation.
This hint is independent of pagination and timestamp ties. New incoming/outgoing
rows must immediately invalidate an older row's hint in the UI until refetched.

Only the **last durable user-visible message** in the conversation can show
interactive flat options or grouped questions. Any newer user or agent message
expires the controls; the original content stays readable. Agent-to-agent inbox
rows do not count as user-visible. Eligibility follows newest durable insertion (SQLite rowid), including equal or
out-of-order timestamps; UI-only synthetic rows never count. History display
retains chronological order (`created_at DESC, message_id DESC`), independently
of eligibility. Visible history pagination returns an opaque `next_cursor` token
(`created_at|message_id`); pass it back unchanged in the URL-encoded `cursor`
query parameter. Timestamp-only legacy cursors remain accepted with their
original strict-before timestamp semantics. Do not infer eligibility from a paginated subset or
rendered run grouping; use the newest durable visible row in the conversation.

## Answer endpoint

`POST /api/v1/chats/{conversation_id}/messages/{source_message_id}/answers`
requires user authentication and conversation/source ownership.

```json
{
  "version": 1,
  "idempotency_key": "client_generated_uuid_kept_for_retries",
  "body": "<vault v2 encrypted readable question/answer summary>",
  "answers": [
    {"question_id": "target", "option_ids": ["staging"]},
    {"question_id": "checks", "custom_text": "<vault v2 encrypted custom answer>"}
  ]
}
```

The client builds and vault-encrypts a readable summary containing each question
and its answer. `body` supports at most 65536 plaintext bytes; `custom_text`
supports at most 8192 plaintext bytes. All submitted human text must be valid v2
vault envelopes; plaintext submissions fail. Use a stable idempotency key
(same ID grammar as question IDs), retain it and the draft on errors, and retry
it to recover a committed success after a lost response.

Supply each question exactly once, in any order. Select known, unique option IDs;
`single` accepts one and `multiple` accepts one or more. A nonempty encrypted
`custom_text` is an alternative: omit `option_ids` or send an empty array. Missing
answers, unknown/duplicate IDs, empty selections, mixed custom/selections, invalid
envelopes, invalid modes/versions, and payload limits produce
`question_invalid` (400). Foreign source/conversation ownership returns 404.

The repository atomically checks the source is the newest visible durable row
while inserting one answer per source. Concurrent submissions cannot deliver
twice. A committed same-key retry returns the original success even after newer
messages; a different key returns `question_answered` (409). An unanswered source
with any newer visible row returns `question_stale` (409). The first successful
request returns 201; a replay returns 200:

```json
{
  "data": {
    "message": {
      "message_id": "msg_answer_msg_source",
      "direction": "user_to_agent",
      "message_type": "multi_question_answer",
      "body": "<vault v2 encrypted readable summary>",
      "metadata": {
        "multi_question_answer": {
          "version": 1,
          "source_message_id": "msg_source",
          "idempotency_key": "client_generated_uuid_kept_for_retries",
          "answers": [{"question_id":"target","option_ids":["staging"]}]
        }
      }
    },
    "question_answer": {
      "answer_message_id": "msg_answer_msg_source",
      "answered_at": "2026-10-22T13:00:00Z"
    },
    "replayed": false
  }
}
```

The response uses the ordinary API success envelope (`data` shown). The durable
`user_to_agent` answer appears in the normal agent inbox with source linkage and
structured IDs. The winning insert emits the existing inbox notification and chat
event; replays emit neither. Stopped instances use the existing restart path after
the answer commits; a restart failure leaves the committed inbox answer readable.
No source metadata mutation or database migration is needed.
