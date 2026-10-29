import { test } from 'node:test';
import assert from 'node:assert/strict';
import './helpers/vaultEndpointHarness.ts';

test('TEST_NOTIFICATION_PLAN and testNotificationFeedback across all runtime environments', async () => {
  const { TEST_NOTIFICATION_PLAN, testNotificationFeedback } = await import('../src/ui/components/settings/NotificationsPanel.tsx');

  assert.equal(TEST_NOTIFICATION_PLAN.title, 'Ninjy test notification', 'plan title');
  assert.ok(TEST_NOTIFICATION_PLAN.body.length > 0, 'plan has a body');
  assert.equal(TEST_NOTIFICATION_PLAN.tag, 'heimdall-test', 'plan uses the heimdall-test coalescing tag');
  assert.equal(TEST_NOTIFICATION_PLAN.category, 'attention', 'plan has a valid category');
  assert.ok(TEST_NOTIFICATION_PLAN.route.startsWith('#/'), 'plan routes to an in-app hash route');

  const cases = [
    { nativeShown: true, electron: false, supported: true, permission: 'granted' },
    { nativeShown: false, electron: true, supported: false, permission: 'unsupported' },
    { nativeShown: false, electron: false, supported: false, permission: 'default' },
    { nativeShown: false, electron: false, supported: true, permission: 'denied' },
    { nativeShown: false, electron: false, supported: true, permission: 'default' },
  ];
  for (const c of cases) {
    const msg = testNotificationFeedback(c);
    assert.ok(typeof msg === 'string' && msg.length > 0, `feedback non-empty for ${JSON.stringify(c)}`);
  }

  assert.match(
    testNotificationFeedback({ nativeShown: true, electron: false, supported: true, permission: 'granted' }),
    /native notification/i,
    'granted+shown => native fired message',
  );
  assert.match(
    testNotificationFeedback({ nativeShown: false, electron: true, supported: false, permission: 'unsupported' }),
    /desktop app/i,
    'electron => desktop-app message',
  );
  assert.match(
    testNotificationFeedback({ nativeShown: false, electron: false, supported: false, permission: 'default' }),
    /no Notifications API/i,
    'unsupported => no-API message',
  );
  assert.match(
    testNotificationFeedback({ nativeShown: false, electron: false, supported: true, permission: 'denied' }),
    /blocked/i,
    'denied => blocked message',
  );

  assert.doesNotThrow(() =>
    testNotificationFeedback({ nativeShown: false, electron: false, supported: true, permission: 'weird' as any }),
  );
});
