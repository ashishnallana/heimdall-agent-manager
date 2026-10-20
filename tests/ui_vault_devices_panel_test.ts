// Settings → Devices built from a VERIFIED chain (utils/devicesPanelModel.ts +
// components/settings/DevicesPanel.tsx DevicesList; plan requirement 3). The current
// device never gets a revoke button; the revoke confirmation lists the devices the
// target approved (revocation does not cascade); the last approver cannot be revoked.
// Hermetic: fake hub built with the production builders.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_devices_panel_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, newBrowser } from './helpers/vaultDirectoryFixture.ts';

const React = (await import('react')).default;
const { renderToStaticMarkup } = await import('react-dom/server');
const { DevicesList } = await import('../src/ui/components/settings/DevicesPanel.tsx');
const { buildDeviceRows } = await import('../src/ui/utils/devicesPanelModel.ts');

/** Root A ("Laptop") approves B ("Phone"); B approves C ("Tablet") and a bridge. */
async function account() {
  const hub = new FakeHub();
  const a = await newBrowser();
  const b = await newBrowser();
  const c = await newBrowser();
  await hub.genesis(a, 'Laptop');
  await hub.addBrowser(a, b, 'Phone');
  await hub.addBrowser(b, c, 'Tablet');
  const bridge = await hub.addBridge(b, 'brg_1', 'build-box');
  return { hub, a, b, c, bridge, chain: await hub.chain() };
}

const html = (rows: any[], confirmRevokeId = '') => renderToStaticMarkup(React.createElement(DevicesList, { rows, confirmRevokeId }));

test('the current device is listed first, marked, and has no revoke button', async () => {
  const { a, b, c, chain } = await account();
  for (const me of [a, b, c]) {
    const rows = await buildDeviceRows(chain, me.deviceId);
    assert.equal(rows[0].deviceId, me.deviceId);
    assert.equal(rows[0].isCurrent, true);
    assert.equal(rows[0].canRevoke, false);
    const out = html(rows);
    assert.match(out, /settings-device-current-badge/);
    assert.doesNotMatch(out, new RegExp(`settings-device-revoke-btn-${me.deviceId}`), 'no revoke for this device');
    for (const other of rows.slice(1)) assert.match(out, new RegExp(`settings-device-revoke-btn-${other.deviceId}`));
  }
});

test('revoke confirmation lists the devices the target approved, from the signed log', async () => {
  const { a, b, chain } = await account();
  const rows = await buildDeviceRows(chain, a.deviceId);
  const rowB = rows.find((r) => r.deviceId === b.deviceId)!;
  assert.deepEqual([...rowB.approvedDeviceLabels].sort(), ['Tablet', 'build-box']);
  const out = html(rows, b.deviceId);
  assert.match(out, new RegExp(`settings-device-revoke-confirm-${b.deviceId}`));
  assert.match(out, new RegExp(`settings-device-revoke-approved-${b.deviceId}`));
  assert.match(out, /Tablet/);
  assert.match(out, /build-box/);
  assert.match(out, /does NOT revoke them/);
  // A device that approved nothing gets no such list.
  const rowC = rows.find((r) => r.label === 'Tablet')!;
  assert.deepEqual(rowC.approvedDeviceLabels, []);
  assert.doesNotMatch(html(rows, rowC.deviceId), /settings-device-revoke-approved-/);
});

test('the last approver cannot be revoked; a device the log revoked has no revoke action', async () => {
  const hub = new FakeHub();
  const a = await newBrowser();
  const b = await newBrowser();
  const c = await newBrowser();
  await hub.genesis(a, 'Laptop');
  await hub.addBrowser(a, b, 'Phone');
  await hub.addBrowser(a, c, 'Tablet');
  await hub.addBridge(a, 'brg_1', 'build-box');
  // A revokes B; C remains, so the last-approver guard allows it.
  await hub.revoke(a, b.deviceId);
  // Seen from C, revoking A would leave C as the only approver.
  const rows = await buildDeviceRows(await hub.chain(), c.deviceId);
  const rowA = rows.find((r) => r.deviceId === a.deviceId)!;
  assert.equal(rowA.canRevoke, false);
  assert.match(rowA.revokeBlockedReason, /Only other approver/);
  const rowB = rows.find((r) => r.deviceId === b.deviceId)!;
  assert.equal(rowB.status, 'revoked');
  assert.doesNotMatch(html(rows), new RegExp(`settings-device-revoke-btn-${b.deviceId}`));
});

test('a bridge that reports "unpaired" (never received keys) is flagged for revoke + re-enroll', async () => {
  const { a, chain } = await account();
  const rows = await buildDeviceRows(chain, a.deviceId);
  const br = rows.find((r) => r.bridgeId === 'brg_1')!;
  assert.doesNotMatch(html(rows), /settings-device-unpaired-hint-/);
  const out = renderToStaticMarkup(React.createElement(DevicesList, { rows, unpairedBridgeIds: ['brg_1'] }));
  assert.match(out, new RegExp(`settings-device-unpaired-hint-${br.deviceId}`));
  assert.match(out, new RegExp(`settings-device-revoke-btn-${br.deviceId}`));
});
