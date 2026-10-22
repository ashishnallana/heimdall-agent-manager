# Multi-question UI evidence

The production `ChatMessageList` and `MultiQuestionForm` are rendered with an
ephemeral vault key and mocked delivery. The fixture never calls a backend or sends
production messages. It is a separate development entry, excluded from the normal
production build.

Firefox 157.0.1 passed all seven browser checks in [results.json](results.json):
native radio arrow keys, checkbox Space, labeled custom text, Tab to submit,
explicit submission, retry draft retention, answered-state projection after reload,
both message directions expiring controls, vault transitions, and a 390px layout
without horizontal overflow. Choice labels and submit targets are at least 44px.
The mobile capture uses desktop browser input in a narrow viewport, not a physical
phone. Backend persistence/atomic idempotency is covered by the reviewed backend;
the UI tests exercise its read model and capture the real encrypted endpoint payload.

- [Desktop and keyboard selection](desktop.png)
- [390px mobile viewport](mobile.png)
- [Retry preserves answers](retry.png)
- [Submitted answers](answered.png)
- [Newer message retires controls](stale.png)
- [Locked vault](locked.png)

Build the standalone fixture with:

```bash
node scripts/build-multi-question-demo.mjs
```

Serve the resulting directory using a managed shell session. Capture with an
existing Puppeteer installation and browser; no dependency changes are required:

```bash
BROWSER=firefox PUPPETEER_MODULE=/path/to/puppeteer-core.js \
CHROME_BIN=/path/to/firefox node scripts/capture-multi-question-evidence.mjs
```

The cached generic Chromium binary was unavailable on this NixOS host because of
its dynamic loader. The installed system Firefox completed the capture instead.
Focused Node/jsdom suites passed 23 chat/vault cases and 33 attention-deck cases;
the configured task verification also runs TypeScript checking.
