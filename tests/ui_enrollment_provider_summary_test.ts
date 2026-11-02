// Post-enrollment provider summary (REQ-ENR-2..5): the reconnect wait, the default
// provider selection, the PUTs "Enable N providers" sends and its label, plus source
// checks that the approval page and ProviderSetupSurface are wired to that logic.
//
// RUN: node --test tests/ui_enrollment_provider_summary_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  RECONNECT_REQUEST_TIMEOUT_MS,
  RECONNECT_TIMEOUT_MS,
  bridgeReconnectReady,
  bridgeStatusPill,
  checkedProviderCount,
  defaultProviderSelection,
  enableButtonLabel,
  isRetriableDiscoveryError,
  modelCountLabel,
  notFoundSummary,
  providerEnableChanges,
  reconnectSecondsLeft,
  reconnectStage,
  startReconnectWait,
  type ProviderSummaryInput,
  type ReconnectTimers,
} from '../src/ui/components/providers/providerSummaryModel.ts';

const read = (rel: string) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

function provider(name: string, over: Partial<ProviderSummaryInput> = {}): ProviderSummaryInput {
  return { provider: name, display_name: name[0].toUpperCase() + name.slice(1), state: 'present', enabled: false, models: [{ state: 'active' }], ...over };
}

/** Timers driven by hand: advance(ms) fires due callbacks in time order. */
function fakeTimers(): ReconnectTimers & { advance(ms: number): Promise<void>; pending(): number } {
  let clock = 0;
  let seq = 0;
  const due = new Map<number, { at: number; fn: () => void; every: number }>();
  const add = (fn: () => void, ms: number, every: number) => { due.set(++seq, { at: clock + ms, fn, every }); return seq; };
  const flush = () => new Promise<void>((resolve) => setImmediate(resolve));
  return {
    now: () => clock,
    setTimeout: (fn, ms) => add(fn, ms, 0),
    clearTimeout: (h) => { due.delete(h as number); },
    setInterval: (fn, ms) => add(fn, ms, ms),
    clearInterval: (h) => { due.delete(h as number); },
    pending: () => due.size,
    async advance(ms) {
      const end = clock + ms;
      for (;;) {
        await flush();
        const next = [...due.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
        if (!next) break;
        const [id, t] = next;
        clock = t.at;
        if (t.every) t.at += t.every; else due.delete(id);
        t.fn();
      }
      clock = end;
      await flush();
    },
  };
}

test('reconnect wait: a GET that never settles cannot freeze the deadline, and only one is ever in flight', async () => {
  const timers = fakeTimers();
  let started = 0;
  let inFlight = 0;
  let maxInFlight = 0;
  let aborted = 0;
  let now = 0;
  let ready = false;
  const stop = startReconnectWait({
    timers,
    poll: (signal) => {
      started += 1;
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      signal.addEventListener('abort', () => { aborted += 1; inFlight -= 1; });
      return new Promise<boolean>(() => {}); // stalled connection: never settles, even on abort
    },
    onReady: () => { ready = true; },
    onTick: (ms) => { now = ms; },
  });
  await timers.advance(RECONNECT_TIMEOUT_MS + 2000);
  assert.equal(now, RECONNECT_TIMEOUT_MS + 2000, 'the clock kept ticking while every GET hung');
  assert.equal(reconnectStage(ready, 0, now), 'timed-out', 'Retry/Skip become available after ~90 s');
  assert.equal(maxInFlight, 1, 'polls are serialized');
  assert.ok(started >= 2 && started <= Math.ceil(RECONNECT_TIMEOUT_MS / RECONNECT_REQUEST_TIMEOUT_MS) + 1, `bounded poll count, got ${started}`);
  assert.equal(aborted, started - inFlight, 'every stalled GET but the current one was aborted');
  stop();
  assert.equal(inFlight, 0, 'stop() aborts the in-flight GET');
  assert.equal(timers.pending(), 0, 'stop() clears the clock and the poll timers');
});

test('reconnect wait: a ready poll wins, failed polls retry, and nothing runs after stop()', async () => {
  const timers = fakeTimers();
  const answers: Array<boolean | Error> = [new Error('offline'), false, true];
  let polls = 0;
  let readyCalls = 0;
  const stop = startReconnectWait({
    timers,
    poll: async () => {
      const answer = answers[polls++];
      if (answer instanceof Error) throw answer;
      return answer;
    },
    onReady: () => { readyCalls += 1; },
    onTick: () => {},
  });
  await timers.advance(10_000);
  assert.equal(polls, 3);
  assert.equal(readyCalls, 1);
  stop();
  await timers.advance(10_000);
  assert.equal(polls, 3, 'no polls after ready + stop');
  assert.equal(timers.pending(), 0);
});

test('reconnect is ready only when the bridge is online AND enrolled', () => {
  assert.equal(bridgeReconnectReady({ status: 'online', enrollment_state: 'enrolled' }), true);
  assert.equal(bridgeReconnectReady({ status: 'ONLINE', enrollment_state: 'enrolled' }), true);
  assert.equal(bridgeReconnectReady({ status: 'offline', enrollment_state: 'enrolled' }), false);
  assert.equal(bridgeReconnectReady({ status: 'online', enrollment_state: 'pending' }), false);
  assert.equal(bridgeReconnectReady({ status: 'online' }), false);
  assert.equal(bridgeReconnectReady(null), false);
  assert.equal(bridgeReconnectReady(undefined), false);
});

test('the reconnect wait times out after ~90 s, but readiness wins on the same tick', () => {
  assert.equal(RECONNECT_TIMEOUT_MS, 90_000);
  const t0 = 1_000_000;
  assert.equal(reconnectStage(false, t0, t0), 'waiting');
  assert.equal(reconnectStage(false, t0, t0 + RECONNECT_TIMEOUT_MS - 1), 'waiting');
  assert.equal(reconnectStage(false, t0, t0 + RECONNECT_TIMEOUT_MS), 'timed-out');
  assert.equal(reconnectStage(true, t0, t0 + RECONNECT_TIMEOUT_MS * 2), 'ready');
  assert.equal(reconnectSecondsLeft(t0, t0), 90);
  assert.equal(reconnectSecondsLeft(t0, t0 + 89_001), 1);
  assert.equal(reconnectSecondsLeft(t0, t0 + 200_000), 0);
});

test('discovery retries only on bridge_offline', () => {
  assert.equal(isRetriableDiscoveryError({ code: 'bridge_offline', status: 409 }), true);
  assert.equal(isRetriableDiscoveryError({ status: 409 }), true, 'a 409 without a code is the offline answer');
  assert.equal(isRetriableDiscoveryError({ code: 'conflict', status: 409 }), false);
  assert.equal(isRetriableDiscoveryError({ code: 'provider_discovery_timeout', status: 504 }), false);
  assert.equal(isRetriableDiscoveryError(new Error('network')), false);
  assert.equal(isRetriableDiscoveryError(null), false);
});

test('defaults: checked iff present with at least one active model; absent providers get no entry', () => {
  const providers = [
    provider('claude', { models: [{ state: 'active' }, { state: 'deprecated' }] }),
    provider('codex', { models: [] }),
    provider('copilot', { models: [{ state: 'deprecated' }] }),
    provider('pi', { state: 'absent', models: [{ state: 'active' }] }),
  ];
  assert.deepEqual(defaultProviderSelection(providers), { claude: true, codex: false, copilot: false });
  assert.equal(checkedProviderCount(providers, defaultProviderSelection(providers)), 1);
  assert.equal(checkedProviderCount(providers, { pi: true, claude: true }), 1, 'absent providers never count');
});

test('only changed enable states of present providers are PUT', () => {
  const providers = [
    provider('claude', { enabled: false }),
    provider('codex', { enabled: true }),
    provider('copilot', { enabled: true }),
    provider('pi', { state: 'absent', enabled: false }),
  ];
  const changes = providerEnableChanges(providers, { claude: true, codex: true, copilot: false, pi: true });
  assert.deepEqual(changes, [{ provider: 'claude', enabled: true }, { provider: 'copilot', enabled: false }]);
  assert.deepEqual(providerEnableChanges(providers, { codex: true, copilot: true }), [], 'unchanged → nothing to send');
});

test('button label, model count and the Not found line', () => {
  assert.equal(enableButtonLabel(0), 'Continue');
  assert.equal(enableButtonLabel(1), 'Enable 1 provider');
  assert.equal(enableButtonLabel(3), 'Enable 3 providers');
  assert.equal(modelCountLabel(1), '1 model');
  assert.equal(modelCountLabel(0), '0 models');
  assert.equal(notFoundSummary([provider('claude'), provider('codex', { state: 'absent' }), provider('pi', { state: 'absent', display_name: 'Pi' })]), 'Not found: Codex, Pi');
  assert.equal(notFoundSummary([provider('claude')]), '');
});

test('the bridge pill follows the real bridge status', () => {
  assert.deepEqual(bridgeStatusPill('online'), { label: 'Online', tone: 'success' });
  assert.deepEqual(bridgeStatusPill('offline'), { label: 'Offline', tone: 'warning' });
});

test('ProviderSetupSurface: no hardcoded Online pill; compact variant uses the shared logic', () => {
  const source = read('../src/ui/components/providers/ProviderSetupSurface.tsx');
  assert.doesNotMatch(source, /<StatusPill tone="success">\{mode === 'enrollment'/);
  assert.match(source, /bridgeStatusPill\(bridge\.status\)/);
  assert.match(source, /variant === 'compact'/);
  assert.match(source, /providerEnableChanges\(payload\.providers, selection\)/);
  assert.match(source, /defaultProviderSelection\(next\.providers\)/);
  assert.match(source, /isRetriableDiscoveryError\(error\)/);
  assert.match(source, /enableButtonLabel\(checked\)/);
  assert.match(source, /Promise\.allSettled/, 'one failing PUT does not stop the others');
});

test('no brg_mock_dawnstar fallback for the standalone provider route', () => {
  assert.doesNotMatch(read('../src/ui/components/shell/AppShell.tsx'), /brg_mock_dawnstar/);
});

test('DeviceApprovalPage: bridge approvals wait for reconnect, then the compact providers step; browsers go straight to done', () => {
  const source = read('../src/ui/components/devices/DeviceApprovalPage.tsx');
  // The approval sequence is shared with the setup wizard (bridgeApproval.ts); the
  // reconnecting phase carries exactly what that sequence approved.
  assert.match(source, /const outcome = await approveBridgeEnrollment\(\{[\s\S]*?target,[\s\S]*?newLabel: finalLabel,/);
  assert.match(source, /setPhase\(\{ kind: 'reconnecting', bridgeId: outcome\.bridgeId, label: outcome\.label, approved: outcome\.approved \}\)/);
  // The reused bridge keeps its own name: the label signed into the approval is
  // approvalLabel(target, newLabel), and the outcome message uses that same label.
  const approval = read('../src/ui/components/devices/bridgeApproval.ts');
  assert.match(approval, /const label = approvalLabel\(target, newLabel\);/);
  assert.match(approval, /buildBridgeApproval\(identity, chain, info, label\)/);
  assert.match(approval, /return \{ bridgeId, label, approved: bridgeApprovedMessage\(target, label, bridgeId, sunset\?\.label \|\| ''\) \};/);
  // REQ-3: a sunset rides on the approval itself (sunset_bridge_id); nothing in the
  // shared sequence revokes a bridge on its own.
  assert.match(approval, /postApproveBridge\(bridgeApproveBody\(keys\.lookup, vault_approval, target, newLabel, sunset\?\.bridge_id \|\| ''\)\)/);
  assert.match(approval, /if \(target && sunset\?\.bridge_id\) throw/);
  assert.doesNotMatch(approval, /revokeBridge|\/revoke/);
  assert.match(approval, /if \(target && bridgeId !== target\.bridge_id\) throw/, 'the hub approving a different bridge than the reuse target is refused');
  assert.match(source, /Waiting for the bridge to restart and reconnect…/);
  assert.match(source, /device-approval-reconnect-retry-btn/);
  assert.match(source, /Skip — configure later in Settings → Providers/);
  assert.match(source, /variant="compact"/);
  assert.match(source, /useListBridgesQuery\(\)/);
  assert.match(source, /startReconnectWait\(\{/, 'the countdown does not wait on the poll');
  assert.match(source, /fetchBridgeRow\(bridgeId, signal\)/, 'reconnect GETs are abortable');
  assert.match(source, /data-debug-id="device-approval-home-btn"[\s\S]*Go to home/);
  assert.match(source, /data-debug-id="device-approval-another-btn"[^>]*onClick=\{reset\}/);
  const browserBranch = source.slice(source.indexOf('if (browser) {'), source.indexOf('const bridgeInfo = info as BridgeCodeInfo;'));
  assert.match(browserBranch, /setPhase\(\{ kind: 'done'/);
  assert.doesNotMatch(browserBranch, /reconnecting/);
});
