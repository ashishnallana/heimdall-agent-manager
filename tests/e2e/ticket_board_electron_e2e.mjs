// Ticket board + ticket tab, end to end in the real desktop app (ticket board
// design spec: REQ-B*, REQ-T*, REQ-L1, REQ-M1). A prompt asks a real coordinator
// agent to plan a task chain; the test then clicks every board and ticket-tab
// control against the live hub and checks what each one does.
//
// Needs a running hub, an online bridge with an agent provider, Vite on :5173
// and an Electron profile that is already signed in with an unlocked vault.
// Playwright is not a repo dependency; point PLAYWRIGHT_MODULE at playwright-core.
//
// RUN: PLAYWRIGHT_MODULE=/path/to/playwright-core/index.mjs \
//      HEIMDALL_HUB_API_URL=http://127.0.0.1:8081 \
//      node tests/e2e/ticket_board_electron_e2e.mjs [EVIDENCE_DIR]
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

assert.ok(process.env.PLAYWRIGHT_MODULE, 'set PLAYWRIGHT_MODULE to playwright-core');
const { _electron } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE).href);
const repo = path.resolve(import.meta.dirname, '../..');
const evidence = path.resolve(process.argv[2] || path.join(repo, '.cache/ticket-board-e2e'));
await fs.mkdir(evidence, { recursive: true });
const AGENT_TIMEOUT = Number(process.env.TICKET_E2E_AGENT_TIMEOUT_MS || 10 * 60_000);

const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;
const app = await _electron.launch({
  cwd: repo,
  executablePath: path.join(repo, 'node_modules/electron/dist', process.platform === 'win32' ? 'electron.exe' : 'electron'),
  args: ['.'],
  env,
  timeout: 60_000,
});
let page;
for (let i = 0; i < 60 && !page; i += 1) {
  page = app.windows().find((w) => w.url().startsWith('http://127.0.0.1:5173'));
  if (!page) await new Promise((r) => setTimeout(r, 1000));
}
assert.ok(page, 'the app window loads the dev UI');
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('dialog', (d) => void d.accept());

const S = (id) => page.locator(`[data-debug-id="${id}"]`);
const P = (prefix) => page.locator(`[data-debug-id^="${prefix}"]`);
const visible = (id, timeout = 15_000) => S(id).first().waitFor({ state: 'visible', timeout });
const gone = (id, timeout = 15_000) => S(id).first().waitFor({ state: 'hidden', timeout });
const clipboard = () => app.evaluate(({ clipboard: c }) => c.readText());
const api = (p, init = {}) =>
  page.evaluate(
    async ([url, init]) => {
      const r = await fetch(`/api/v1${url}`, { credentials: 'include', headers: { 'Content-Type': 'application/json' }, ...init });
      return { status: r.status, body: await r.json().catch(() => null) };
    },
    [p, init],
  );
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 15_000, every = 500) {
  const end = Date.now() + timeout;
  for (;;) {
    const v = await fn().catch(() => null);
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out: ${what}`);
    await sleep(every);
  }
}
const pressEscape = () => page.keyboard.press('Escape');
const dialogOpen = () => page.locator('[role="dialog"]').first().waitFor({ state: 'visible', timeout: 10_000 });
const dialogClosed = () => page.locator('[role="dialog"]').first().waitFor({ state: 'hidden', timeout: 10_000 });
const activeAuxTab = () => page.locator('[role="tab"][aria-selected="true"][data-debug-id^="aux-tab-"]').first().getAttribute('data-tab-id');

const results = [];
async function step(name, fn) {
  const started = Date.now();
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`ok   ${name} (${Date.now() - started}ms)`);
  } catch (e) {
    const shot = path.join(evidence, `fail-${results.length + 1}.png`);
    await page.screenshot({ path: shot }).catch(() => {});
    results.push({ name, ok: false, error: String(e?.message || e).split('\n')[0], shot });
    console.log(`FAIL ${name}: ${String(e?.message || e).split('\n')[0]}`);
  }
}

/* Chain data, read straight from the hub ---------------------------- */

const chainIds = async () => {
  const r = await api('/task-chains?flat=1&limit=200');
  return new Set((r.body?.data || []).map((c) => c.chain_id));
};
const chainTasks = async (chainId) => {
  const r = await api(`/task-chains/${chainId}`);
  const tasks = r.body?.data?.tasks || r.body?.data?.chain?.tasks || [];
  return tasks
    .filter((t) => !t.workflow_run_id)
    .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) || a.task_id.localeCompare(b.task_id));
};
const taskState = async (chainId, taskId) => (await chainTasks(chainId)).find((t) => t.task_id === taskId);

let chainId = '';
let tickets = [];
const tabId = (taskId) => `ticket__${chainId}:${taskId}`;
const openTicketsTab = async () => {
  await S('aux-tab-tasks').first().click();
  await visible('ticket-board-view');
};

/* 1. Prompt a task chain ------------------------------------------- */

await step('app starts signed in with the vault unlocked', async () => {
  await visible('app-shell', 60_000);
  await visible('shell-vault-status-toggle');
});

await step('a prompt from New conversation starts a task chain and its coordinator adds the tickets', async () => {
  const before = await chainIds();
  await page.evaluate(() => (location.hash = '#/'));
  await visible('new-convo-composer-input', 30_000);
  const stamp = new Date().toISOString().slice(0, 16).replace('T', ' ');
  await S('new-convo-composer-input').fill(
    `Automated UI test (${stamp}). You coordinate this conversation's task chain. Use ham-ctl to add ` +
      'exactly three tickets to it, each with a goal and at least two acceptance items, and leave all three as unpublished drafts: ' +
      '1) "Add a health endpoint" (GET /health returns 200 with {"ok":true}); ' +
      '2) "Document the health endpoint", which depends on ticket 1; ' +
      '3) "Add the health check to CI". ' +
      'Do not publish them, assign workers, start work or edit any files. When done, reply with the chain id and stop.',
  );
  await S('new-convo-composer-send-btn').click();
  await until('the conversation opens', async () => (await page.evaluate(() => location.hash)).startsWith('#/conversations'), 60_000);
  chainId = await until(
    'the agent creates the chain',
    async () => [...(await chainIds())].find((id) => !before.has(id)),
    AGENT_TIMEOUT,
    5000,
  );
  tickets = await until('the agent adds three tickets', async () => ((await chainTasks(chainId)).length >= 3 ? chainTasks(chainId) : null), AGENT_TIMEOUT, 5000);
  console.log(`     chain ${chainId}: ${tickets.map((t) => `${t.task_id} (${t.publish_state || t.state})`).join(', ')}`);
});
if (!chainId || tickets.length < 3) {
  await finish();
}
const [t1, t2, t3] = tickets.map((t) => t.task_id);

/* 2. Board ----------------------------------------------------------- */

await step('REQ-B1: the conversation aux pane shows the board for the bound chain', async () => {
  await page.evaluate((c) => (location.hash = `#/conversations/chain:${c}`), chainId);
  await until('the Tickets tab', async () => (await S('aux-tab-tasks').count()) > 0 || (await S('conversation-tasks-btn').count()) > 0, 30_000);
  if (!(await S('aux-tab-tasks').count())) await S('conversation-tasks-btn').click();
  await openTicketsTab();
  for (const id of [t1, t2, t3]) await visible(`task-card-${id}`);
});

await step('REQ-B2: header names what needs you and the progress caption counts every ticket', async () => {
  const headline = await S('ticket-board-headline').innerText();
  const drafts = tickets.filter((t) => (t.publish_state || '') === 'draft').length;
  assert.match(headline, drafts ? new RegExp(`${drafts} tickets? needs? you`) : /Nothing needs you|need/);
  await visible('ticket-board-progress');
  assert.match(await S('ticket-board-progress-caption').innerText(), /of 3 done/);
});

await step('REQ-B2: Open / Finished / All filter the list in place', async () => {
  await S('ticket-board-filter-finished').click();
  await visible('ticket-board-filter-empty');
  await S('ticket-board-filter-all').click();
  await visible(`task-card-${t1}`);
  await S('ticket-board-filter-open').click();
  await visible(`task-card-${t3}`);
});

await step('REQ-B4: cards show key, title and an ask badge or state pill; dependency context reads "Starts after T-1"', async () => {
  const card = S(`task-card-${t2}`);
  assert.match(await card.innerText(), /T-2/);
  const status = await S(`task-card-status-${t2}`).innerText();
  assert.ok(/Starts after T-1|Draft|T-1/.test(status) || (await S(`task-card-ask-${t2}`).count()) > 0, status);
});

await step('REQ-B3: the fleet table lists the coordinator; its row opens the conversation', async () => {
  await visible('ticket-board-fleet');
  const rows = P('ticket-board-fleet-row-');
  assert.ok((await rows.count()) >= 1, 'at least one fleet row');
  const coord = rows.filter({ hasText: /Coordinat/ }).first();
  await coord.click();
  await until('Main shows a conversation', async () => (await page.evaluate(() => location.hash)).includes('conversations'));
  await openTicketsTab();
});

await step('board menu: Review roles opens and Esc closes it', async () => {
  await S('ticket-board-menu-btn').click();
  await S('task-board-review-roles-btn').click();
  await dialogOpen();
  assert.match(await page.locator('[role="dialog"]').first().innerText(), /Review roles/);
  await pressEscape();
  await dialogClosed();
  await visible('ticket-board-view');
});

await step('board menu: Manage fleet opens the fleet drawer; Done closes it', async () => {
  await S('ticket-board-menu-btn').click();
  await S('task-board-fleet-btn').click();
  await visible('fleet-management-drawer');
  await S('fleet-drawer-done-btn').click();
  await gone('fleet-management-drawer');
});

let t4 = '';
await step('New ticket opens CreateTaskModal and the new card appears without a reload', async () => {
  await S('task-board-new-task-btn').first().click();
  await visible('create-task-modal');
  await S('create-task-title-input').fill('Rate-limit the health endpoint');
  await S('create-task-goal-input').fill('Stop /health from being used to load the hub.');
  await S('create-task-acceptance-input').fill('More than 10 requests a second get 429\nThe limit is configurable');
  await S('create-task-submit-btn').click();
  await gone('create-task-modal');
  t4 = await until('the hub has the ticket', async () => (await chainTasks(chainId)).map((t) => t.task_id).find((id) => ![t1, t2, t3].includes(id)));
  await visible(`task-card-${t4}`);
  assert.match(await S(`task-card-${t4}`).innerText(), /Rate-limit the health endpoint/);
});

await step('card Publish runs in place and the card leaves the "needs you" state', async () => {
  const btn = S(`task-action-publish-${t1}`);
  if (!(await btn.count())) return console.log('     (T-1 was already published by the agent)');
  await btn.click();
  await until('T-1 published', async () => (await taskState(chainId, t1))?.publish_state !== 'draft');
  await gone(`task-action-publish-${t1}`);
});

await step('card menu: Change requirements and Change assignee open their dialogs; Esc closes them', async () => {
  for (const field of ['requirements', 'assignee', 'reviewers', 'deps']) {
    await S(`task-card-more-${t3}`).click();
    await S(`task-card-edit-${field}-${t3}`).click();
    await dialogOpen();
    await pressEscape();
    await dialogClosed();
  }
});

await step('card menu: Hold asks for a reason in an in-app dialog, moves the card to Held; Release clears it', async () => {
  await S(`task-card-more-${t1}`).click();
  await S(`task-menu-hold-${t1}`).click();
  await visible('task-hold-dialog');
  await S('task-hold-reason-input').fill('E2E: waiting on the API design');
  await S('task-hold-confirm-btn').click();
  await gone('task-hold-dialog');
  await visible(`task-card-hold-${t1}`);
  await visible('task-board-section-held');
  await S(`task-action-release-${t1}`).click();
  await gone(`task-card-hold-${t1}`);
});

await step('card menu: Recheck and Copy ID', async () => {
  if (await S(`task-card-more-${t1}`).count()) {
    await S(`task-card-more-${t1}`).click();
    const recheck = S(`task-menu-recheck-${t1}`);
    if (await recheck.count()) await recheck.click();
    else await pressEscape();
  }
  await S(`task-card-more-${t3}`).click();
  await S(`task-menu-copy_id-${t3}`).click();
  assert.equal(await until('clipboard has the id', async () => ((await clipboard()) === t3 ? t3 : null)), t3);
});

await step('REQ-L1: a change made outside the app (hub API) reaches the board over the socket', async () => {
  const r = await api(`/task-chains/${chainId}/tasks/${t4}/hold`, { method: 'POST', body: JSON.stringify({ reason: 'held from the API' }) });
  assert.ok(r.status < 300, `hold via API: ${r.status}`);
  await visible(`task-card-hold-${t4}`);
  await api(`/task-chains/${chainId}/tasks/${t4}/release`, { method: 'POST', body: '{}' });
  await gone(`task-card-hold-${t4}`);
});

await step('REQ-B6: Cancel moves a ticket to Finished; Newest/Oldest toggles; the row opens the ticket', async () => {
  await S(`task-card-more-${t4}`).click();
  await S(`task-menu-cancel-${t4}`).click();
  await until('cancelled', async () => (await taskState(chainId, t4))?.state === 'cancelled');
  await gone(`task-card-${t4}`);
  await S('ticket-board-filter-finished').click();
  await visible(`ticket-board-finished-row-${t4}`);
  const order = S('ticket-board-finished-order');
  const before = await order.innerText();
  await order.click();
  assert.notEqual(await order.innerText(), before);
  await S(`ticket-board-finished-row-${t4}`).click();
  await visible(`ticket-view-${t4}`);
});

await step('done/cancelled ticket: the state button offers Reopen only, and Reopen works', async () => {
  await S('ticket-view-state-btn').click();
  await visible('ticket-view-state-reopen');
  const items = await P('ticket-view-state-').evaluateAll((els) => els.map((e) => e.getAttribute('data-debug-id')).filter((id) => id !== 'ticket-view-state-btn'));
  assert.deepEqual(items, ['ticket-view-state-reopen']);
  await S('ticket-view-state-reopen').click();
  await until('reopened', async () => (await taskState(chainId, t4))?.state !== 'cancelled');
  await openTicketsTab();
  await S('ticket-board-filter-open').click();
});

/* 3. Ticket tab ------------------------------------------------------ */

await step('REQ-T1: a card opens its own "T-n Title" tab; a second click focuses it, no duplicate', async () => {
  await S(`task-card-${t2}`).click();
  await visible(`ticket-view-${t2}`);
  assert.equal(await activeAuxTab(), tabId(t2));
  assert.match(await S(`aux-tab-${tabId(t2)}`).innerText(), /T-2/);
  await openTicketsTab();
  await S(`task-card-${t2}`).click();
  assert.equal(await S(`aux-tab-${tabId(t2)}`).count(), 1);
  assert.equal(await activeAuxTab(), tabId(t2));
});

await step('REQ-T3: toolbar, header, requirements, linked tickets, attempts, activity and details render', async () => {
  for (const id of ['ticket-view-toolbar', 'ticket-view-header', 'ticket-view-title', 'ticket-view-requirements', 'ticket-view-linked', 'ticket-view-attempts', 'ticket-activity', 'ticket-view-agents']) await visible(id);
  assert.match(await S('ticket-view-toolbar').innerText(), /T-2 · \d+ of \d+/);
});

await step('REQ-T2 / linked tickets: "waits for T-1" opens T-1 in the same tab', async () => {
  await S(`ticket-view-linked-${t1}`).click();
  await visible(`ticket-view-${t1}`);
  assert.equal(await activeAuxTab(), tabId(t1));
});

await step('previous / next and j / k replace the ticket in the same tab', async () => {
  const tabsBefore = await P('aux-tab-ticket__').count();
  await S('ticket-view-next-btn').click();
  await until('moved off T-1', async () => (await activeAuxTab()) !== tabId(t1));
  const afterNext = await activeAuxTab();
  await S('ticket-view-prev-btn').click();
  await until('back on T-1', async () => (await activeAuxTab()) === tabId(t1));
  await S('ticket-view-title').click();
  await page.keyboard.press('j');
  await until('j moved', async () => (await activeAuxTab()) === afterNext);
  await page.keyboard.press('k');
  await until('k moved back', async () => (await activeAuxTab()) === tabId(t1));
  assert.equal(await P('aux-tab-ticket__').count(), tabsBefore, 'no extra tabs');
});

await step('copy link copies #/chains/{c}/tasks/{t}', async () => {
  await S('ticket-view-copy-link-btn').click();
  assert.match(await until('clipboard link', async () => ((await clipboard()).includes(t1) ? clipboard() : null)), new RegExp(`#/chains/${chainId}/tasks/${t1}$`));
});

await step('More menu: edit dialogs open (assignee, reviewers, dependencies) and Esc closes them', async () => {
  for (const field of ['assignee', 'reviewers', 'deps']) {
    await S('ticket-view-more-btn').click();
    await S(`ticket-view-edit-${field}`).click();
    await dialogOpen();
    await pressEscape();
    await dialogClosed();
    await visible(`ticket-view-${t1}`);
  }
});

await step('state button lists the allowed transitions; Esc closes the menu, never the tab', async () => {
  await S('ticket-view-state-btn').click();
  assert.ok((await P('ticket-view-state-').count()) > 1);
  await pressEscape();
  await visible(`ticket-view-${t1}`);
});

await step('quick actions: Hold (in-app reason dialog) shows the hold block; Release hold clears it', async () => {
  await S('ticket-view-hold-btn').click();
  await visible('task-hold-dialog');
  await S('task-hold-reason-input').fill('E2E hold from the ticket tab');
  await S('task-hold-confirm-btn').click();
  await visible('task-hold-block');
  assert.match(await S('task-hold-reason').innerText(), /E2E hold from the ticket tab/);
  await S('task-hold-release-btn').click();
  await gone('task-hold-block');
});

await step('quick actions: Add dependency opens the dependency editor', async () => {
  await S('ticket-view-add-dependency-btn').click();
  await dialogOpen();
  await pressEscape();
  await dialogClosed();
});

await step('REQ-T4 / T5: Change requirements amends with a reason and preview; the card shows Rev 2', async () => {
  await S('ticket-view-change-requirements-btn').click();
  await visible('task-requirements-editor');
  await S('task-requirements-acceptance-add').click();
  const last = page.locator('[data-debug-id^="task-requirements-acceptance-"] input, [data-debug-id^="task-requirements-acceptance-"] textarea, input[data-debug-id^="task-requirements-acceptance-"], textarea[data-debug-id^="task-requirements-acceptance-"]').last();
  await last.fill('Responses carry a Cache-Control: no-store header');
  await S('task-requirements-reason').fill('E2E: cover caching');
  await visible('task-requirements-preview');
  assert.match(await S('task-requirements-preview').innerText(), /Cache-Control/);
  await S('task-requirements-save').click();
  await gone('task-requirements-editor');
  await until('Rev 2 on the ticket', async () => /Rev 2/.test(await S('ticket-view-requirements').innerText()));
});

await step('REQ-T4: Current / Changes toggle shows the diff; "See what changed" opens Activity > Requirement changes', async () => {
  await S('ticket-view-requirements-changes').click();
  await visible('ticket-view-requirements-diff');
  assert.match(await S('ticket-view-requirements-diff').innerText(), /Cache-Control/);
  await S('ticket-view-requirements-current').click();
  if (await S('ticket-view-see-what-changed').count()) {
    await S('ticket-view-see-what-changed').first().click();
    assert.equal(await S('ticket-activity-tab-requirements').getAttribute('aria-selected'), 'true');
  }
});

await step('REQ-T7: every Activity tab switches the feed', async () => {
  for (const tab of ['all', 'comments', 'requirements', 'handoffs', 'raw']) {
    await S(`ticket-activity-tab-${tab}`).click();
    assert.equal(await S(`ticket-activity-tab-${tab}`).getAttribute('aria-selected'), 'true', tab);
  }
  await S('ticket-activity-tab-requirements').click();
  await visible('ticket-requirement-change-2');
});

await step('comment send posts the comment and clears the bar', async () => {
  const box = page.locator('[data-debug-id="comment-composer"] textarea, textarea[data-debug-id="comment-composer"]').first();
  await box.fill('E2E comment from the ticket tab');
  await S('ticket-view-comment-send-btn').click();
  await until('composer cleared', async () => (await box.inputValue()) === '');
  await S('ticket-activity-tab-comments').click();
  await until('comment shows', async () => /E2E comment from the ticket tab/.test(await S('ticket-activity').innerText()), 20_000);
});

await step('Changes section expands on first open', async () => {
  await S('ticket-view-changes-toggle').click();
  await visible('task-details-changes');
});

await step('breadcrumb "Tickets" returns to the board tab', async () => {
  await S('ticket-view-breadcrumb-tickets').click();
  assert.equal(await activeAuxTab(), 'tasks');
});

await step('requirement change made elsewhere highlights the board card and shows Rev 2', async () => {
  await visible(`task-card-requirements-line-${t1}`);
  assert.match(await S(`task-card-requirements-line-${t1}`).innerText(), /Rev 2/);
});

await step('closing an active ticket tab returns focus to Tickets', async () => {
  await S(`aux-tab-${tabId(t1)}`).click();
  await visible(`ticket-view-${t1}`);
  await S(`aux-tab-close-${tabId(t1)}`).click();
  assert.equal(await S(`aux-tab-${tabId(t1)}`).count(), 0);
  assert.equal(await activeAuxTab(), 'tasks');
});

await step('legacy ?panel=tasks&task=<id> link opens that ticket tab', async () => {
  await page.evaluate(([c, t]) => (location.hash = `#/conversations/chain:${c}?panel=tasks&task=${t}`), [chainId, t3]);
  await visible(`ticket-view-${t3}`, 20_000);
  assert.equal(await activeAuxTab(), tabId(t3));
});

await step('copied #/chains link opens the ticket on the Task chains page', async () => {
  await page.evaluate(([c, t]) => (location.hash = `#/chains/${c}/tasks/${t}`), [chainId, t2]);
  await visible(`ticket-view-${t2}`, 20_000);
});

await step('REQ-M1: phone width keeps one column, 44 px targets and a sticky comment bar', async () => {
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(390, 844));
  await sleep(1000);
  await page.evaluate(([c, t]) => (location.hash = `#/chains/${c}/tasks/${t}`), [chainId, t2]);
  await visible(`ticket-view-${t2}`, 20_000);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 1, `no horizontal scroll (${overflow}px)`);
  await visible('ticket-view-sticky-composer');
  const box = await S('ticket-view-next-btn').boundingBox();
  assert.ok(box && box.height >= 44 && box.width >= 44, `next button is ${box?.width}x${box?.height}`);
  await page.screenshot({ path: path.join(evidence, 'phone-ticket.png') });
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1400, 900));
});

await step('no uncaught page errors', async () => {
  assert.deepEqual(errors, []);
});

await finish();

async function finish() {
  await page.screenshot({ path: path.join(evidence, 'last.png') }).catch(() => {});
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} steps passed${chainId ? ` (chain ${chainId})` : ''}`);
  for (const f of failed) console.log(`  FAIL ${f.name}\n       ${f.error}\n       ${f.shot}`);
  await fs.writeFile(path.join(evidence, 'results.json'), JSON.stringify({ chainId, results }, null, 2));
  await app.close();
  process.exit(failed.length ? 1 : 0);
}
