# Quoted context
Selecting text inside an ordinary agent chat message offers **Quote**. Activating it opens the chain coordinator composer and adds a removable chip showing the first six words. Expand a chip for the snapshot and source link. Your typed draft remains separate; only normal **Send** sends the text and context together. Quotes alone can also be sent.

The capture adapter constructs a version-1 QuoteContext (selectedText, capturedAt and typed source); the composer does not need to know how that source was captured. agent_message records the source message/conversation/instance/chain identifiers, author, time and internal link. The source union also defines task, task_comment and preview_selection contracts for future adapters; those capture UIs are not implemented yet.

The common serializer appends versioned JSON under “Quoted context (source material)” to the normal message body, choosing a fence longer than every backtick run in the payload. Snapshot text retains its whitespace and source metadata is part of the same Vault-encrypted body. There is no separate plaintext context API field or Hub schema migration. Agents receive source material as context, not a new system instruction.

Quotes are staged by chain target, not a worker instance, and the current coordinator is resolved before capture and revalidated before sending. Missing/changed targets cannot silently redirect the message to a worker. Selection never sends automatically. Borrowed Answer/Request changes modes do not include normal-chat quotes.

Chips live only in memory: switching panes retains them, but reload, Vault key purge or user switch clears them. Selected decrypted text is not copied into localStorage. Existing typed-draft persistence is unchanged. Failed sends retain the draft, attachments and quote chips for retry; successful sends consume only the submitted chips. New additions are not discarded. The normal composer is disabled while its send is pending.

Limits are eight quotes, 8,000 JavaScript string characters per selection and 64,000 total. An oversize selection is rejected with a visible explanation, never silently clipped. Repeated identical source/selection captures do not add duplicates.

First-phase exclusions: user/system messages, action controls, encrypted/unreadable placeholders, ranges spanning messages, standalone messages without a resolvable chain coordinator, and cross-origin iframe content. Native browser selection handles and popover placement should also be checked on the actual desktop/mobile clients; DOM tests cover event handling but do not emulate native touch handles.
