import { test } from 'node:test';
import assert from 'node:assert/strict';
import './helpers/vaultEndpointHarness.ts';

test('bridgeLaunchOptions pure option derivation for launch/add-agent dropdowns', async () => {
  const {
    bridgeIdOf,
    bridgeIsOnline,
    bridgeLabel,
    launchProvidersFor,
    launchModelsFor,
    launchableBridgeRows,
    capSupports,
  } = await import('../src/ui/utils/bridgeLaunchOptions.ts');

  const onlineBridge = {
    bridge_id: 'brg_1',
    label: 'Mac Studio',
    status: 'online',
    capabilities: {
      providers: [
        { provider: 'anthropic', models: ['cheap', 'smart'], default_model: 'smart' },
        { provider: 'openai', models: ['normal'] },
      ],
    },
  };
  const offlineBridge = { bridge_id: 'brg_off', status: 'offline', capabilities: { providers: [{ provider: 'anthropic', models: ['normal'] }] } };
  const onlineNoCaps = { bridge_id: 'brg_empty', status: 'online', capabilities: { providers: [] } };

  assert.equal(bridgeIdOf(onlineBridge), 'brg_1');
  assert.equal(bridgeIdOf({ bridgeId: 'x' }), 'x');
  assert.equal(bridgeIdOf({ id: 'y' }), 'y');
  assert.equal(bridgeIsOnline(onlineBridge), true);
  assert.equal(bridgeIsOnline(offlineBridge), false);
  assert.equal(bridgeLabel(onlineBridge), 'Mac Studio');
  assert.equal(bridgeLabel({ bridge_id: 'brg_z', machine_hostname: 'host-z' }), 'host-z');
  assert.equal(bridgeLabel({ bridge_id: 'brg_z' }), 'brg_z');

  assert.deepEqual(launchProvidersFor(onlineBridge), ['anthropic', 'openai']);
  assert.deepEqual(launchProvidersFor(onlineNoCaps), []);

  assert.deepEqual(launchModelsFor(onlineBridge, 'anthropic'), ['cheap', 'smart']);
  assert.deepEqual(launchModelsFor(onlineBridge, 'openai'), ['normal']);
  assert.deepEqual(launchModelsFor(onlineBridge, ''), []);

  assert.equal(capSupports(onlineBridge, 'anthropic', 'smart'), true);
  assert.equal(capSupports(onlineBridge, 'anthropic', 'normal'), false, 'anthropic does not advertise normal');
  assert.equal(capSupports(onlineBridge, 'openai', 'normal'), true);
  assert.equal(capSupports(onlineBridge, '', 'smart'), false, 'no provider => unsupported');
  assert.equal(capSupports(onlineBridge, 'anthropic', ''), false, 'no model => unsupported');

  const rows = launchableBridgeRows([onlineBridge, offlineBridge, onlineNoCaps]);
  assert.equal(rows.length, 1, 'only the online-with-caps bridge is launchable');
  assert.equal(rows[0].bridgeId, 'brg_1');

  assert.deepEqual(launchableBridgeRows([]), []);
  assert.deepEqual(launchableBridgeRows(undefined as any), []);
  assert.deepEqual(launchProvidersFor({}), []);
  assert.deepEqual(launchModelsFor({}, 'anthropic'), []);
});
