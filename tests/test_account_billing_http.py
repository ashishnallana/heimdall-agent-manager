"""Real hub billing smoke test. Set HEIMDALL_BILLING_TEST_BINARY to a built hub.

Uses a temporary database, random loopback port, and fake webhook secret. It
never contacts Paddle or an existing hub/bridge.
"""
import hashlib
import hmac
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


class AccountBillingHTTPTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='heimdall-billing-http-')
        self.hub_bin = os.environ.get('HEIMDALL_BILLING_TEST_BINARY')
        if not self.hub_bin or not Path(self.hub_bin).exists():
            built = Path(self.directory.name) / 'ham-hub'
            subprocess.run(
                ['nix', 'develop', '--command', 'odin', 'build', 'src/hub', '-collection:odin_test=src', f'-out:{built}'],
                cwd=ROOT, check=True, capture_output=True, text=True,
            )
            self.hub_bin = str(built)
        self.database = str(Path(self.directory.name) / 'hub.db')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.base = f'http://127.0.0.1:{self.port}'
        self.log = open(Path(self.directory.name) / 'hub.log', 'wb')
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('HEIMDALL_PADDLE_') and key != 'HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS'}
        self.env.update(HEIMDALL_PADDLE_WEBHOOK_SECRET='test_only_secret', HEIMDALL_PADDLE_HOBBYIST_PRICE_ID='pri_approved', HEIMDALL_PADDLE_ENVIRONMENT='sandbox')
        self.start_hub()

    def start_hub(self):
        self.process = subprocess.Popen([self.hub_bin, '--listen', f'127.0.0.1:{self.port}', '--db', self.database, '--migrations-dir', '/nonexistent/billing-test-migrations', '--ui-origin', 'http://127.0.0.1:5193', *getattr(self, 'hub_args', [])], env=self.env, stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                status, _ = self.request('GET', '/api/v1/me', user='alice')
                if status == 200:
                    return
            except OSError:
                pass
            if self.process.poll() is not None:
                self.fail('hub exited during startup')
            time.sleep(0.05)
        self.fail('hub did not start')

    def tearDown(self):
        if hasattr(self, 'process') and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.log.close()
        self.directory.cleanup()

    def request(self, method, path, data=None, user=None, extra=None):
        headers = {'Content-Type': 'application/json'}
        if user:
            headers.update({'X-authentik-username': user, 'X-authentik-name': user.title(), 'X-authentik-email': f'{user}@example.com'})
        headers.update(extra or {})
        body = json.dumps(data, separators=(',', ':')).encode() if data is not None else None
        req = urllib.request.Request(self.base + path, data=body, method=method, headers=headers)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        raw = response.read().decode('utf-8', errors='replace')
        return response.status, (json.loads(raw) if raw.lstrip().startswith(('{', '[')) else {'raw': raw})

    def webhook(self, event_id, status, occurred_at):
        event = {'event_id': event_id, 'event_type': 'subscription.updated', 'occurred_at': occurred_at, 'data': {'id': 'sub_alice', 'customer_id': 'ctm_alice', 'status': status, 'custom_data': {'heimdall_checkout_reference': 'server_reference'}, 'scheduled_change': None, 'next_billed_at': '2026-11-10T10:00:00Z', 'items': [{'price': {'id': 'pri_approved'}}]}}
        body = json.dumps(event, separators=(',', ':')).encode()
        timestamp = str(int(time.time()))
        signature = hmac.new(b'test_only_secret', timestamp.encode() + b':' + body, hashlib.sha256).hexdigest()
        return self.request('POST', '/api/v1/billing/paddle/webhook', event, extra={'Paddle-Signature': f'ts={timestamp};h1={signature}'})

    def test_billing_persistence_webhooks_and_authentication(self):
        self.assertEqual(self.request('GET', '/api/v1/account/billing')[0], 401)
        # Authentik provisioning persists defaults before opening Account.
        with sqlite3.connect(self.database) as conn:
            self.assertEqual(conn.execute("SELECT max_bridges, terminal_streaming_enabled FROM account_entitlements WHERE user_id = 'alice'").fetchone(), (1, 1))
        status, body = self.request('GET', '/api/v1/account/billing', user='alice')
        self.assertEqual(status, 200)
        self.assertEqual(body['data']['entitlements'], {'max_bridges': 1, 'terminal_streaming_enabled': True, 'terminal_input_enabled': False, 'max_concurrent_streams': 2, 'shells_enabled': False})
        self.assertFalse(body['data']['checkout_enabled'])
        self.assertNotIn('api_key', body['data'])
        self.assertEqual(self.request('POST', '/api/v1/account/billing/checkout', {'offer_id': 'hobbyist'}, user='alice', extra={'Origin': 'https://evil.example'})[0], 403)
        self.assertEqual(self.request('POST', '/api/v1/account/billing/checkout', {'offer_id': 'hobbyist'}, user='alice', extra={'Content-Type': 'text/plain'})[0], 400)
        self.assertEqual(self.request('POST', '/api/v1/account/billing/checkout', {'offer_id': 'hobbyist'}, user='alice', extra={'Origin': 'http://127.0.0.1:5193'})[0], 501)
        self.assertEqual(self.request('GET', '/api/v1/account/billing', user='alice', extra={'Authorization': 'Bearer hba_bad'})[0], 403)
        token_status, issued = self.request('POST', '/api/v1/me/tokens', {'label': 'billing-test'}, user='alice')
        self.assertEqual(token_status, 201)
        bearer = {'Authorization': 'Bearer ' + issued['data']['plaintext']}
        self.assertEqual(self.request('GET', '/api/v1/account/billing', extra=bearer)[0], 200)
        self.assertEqual(self.request('POST', '/api/v1/account/billing/checkout', {'offer_id': 'hobbyist'}, extra=bearer)[0], 501)
        self.assertEqual(self.request('POST', '/api/v1/billing/paddle/webhook', {}, extra={'Paddle-Signature': 'ts=0;h1=invalid'})[0], 401)
        with sqlite3.connect(self.database) as conn:
            conn.execute("INSERT INTO billing_checkouts(reference, user_id, plan_id, price_id, expires_at) VALUES ('server_reference', 'alice', 'hobbyist', 'pri_approved', '2099-01-01T00:00:00Z')")
        self.assertEqual(self.webhook('evt_active', 'active', '2026-10-10T10:00:00.123456Z')[0], 200)
        self.assertEqual(self.webhook('evt_active', 'active', '2026-10-10T10:00:00.123456Z')[0], 200)
        self.assertEqual(self.webhook('evt_stale', 'canceled', '2026-10-10T09:00:00.123456Z')[0], 200)
        _, active = self.request('GET', '/api/v1/account/billing', user='alice')
        self.assertEqual(active['data']['plan_label'], 'Hobbyist')
        self.assertTrue(active['data']['entitlements']['terminal_streaming_enabled'])
        _, bob = self.request('GET', '/api/v1/account/billing', user='bob')
        self.assertTrue(bob['data']['entitlements']['terminal_streaming_enabled'])
        self.assertFalse(bob['data']['entitlements']['terminal_input_enabled'])
        with sqlite3.connect(self.database) as conn:
            conn.execute("UPDATE account_entitlements SET override_max_bridges = 6, override_terminal_streaming_enabled = 0, override_reason = 'test agreement', override_updated_by = 'test' WHERE user_id = 'alice'")
        self.process.terminate()
        self.process.wait(timeout=5)
        self.start_hub()
        _, restarted = self.request('GET', '/api/v1/account/billing', user='alice')
        self.assertEqual(restarted['data']['entitlements'], {'max_bridges': 6, 'terminal_streaming_enabled': False, 'terminal_input_enabled': True, 'max_concurrent_streams': -1, 'shells_enabled': True})
        self.assertEqual(self.webhook('evt_canceled', 'canceled', '2026-10-10T11:00:00.123456Z')[0], 200)
        _, canceled = self.request('GET', '/api/v1/account/billing', user='alice')
        self.assertEqual(canceled['data']['plan_label'], 'Free')
        self.assertEqual(canceled['data']['entitlements']['max_bridges'], 6)
        with sqlite3.connect(self.database) as conn:
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM billing_events').fetchone()[0], 3)
            self.assertEqual(conn.execute("SELECT terminal_streaming_enabled FROM account_entitlements WHERE user_id = 'alice'").fetchone()[0], 0)

    def test_explicit_enforcement_config_and_flag_precedence(self):
        def restart():
            self.process.terminate()
            self.process.wait(timeout=5)
            self.start_hub()

        def entitlements():
            status, body = self.request('GET', '/api/v1/account/billing', user='alice')
            self.assertEqual(status, 200)
            return body['data']['entitlements']

        # The webhook-only default is enforced even though checkout is disabled.
        self.assertEqual(entitlements()['max_bridges'], 1)
        self.env = {key: value for key, value in self.env.items() if not key.startswith('HEIMDALL_PADDLE_')}
        restart()
        self.assertEqual(entitlements(), {
            'max_bridges': -1, 'terminal_streaming_enabled': True,
            'terminal_input_enabled': True, 'max_concurrent_streams': -1, 'shells_enabled': True,
        })
        self.env['HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS'] = 'true'
        restart()
        self.assertEqual(entitlements()['max_bridges'], 1)
        self.hub_args = ['--billing-enforce-plan-limits', 'false']
        restart()
        self.assertEqual(entitlements()['max_bridges'], -1)
        self.env['HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS'] = 'false'
        self.hub_args = ['--billing-enforce-plan-limits', 'true']
        restart()
        self.assertEqual(entitlements()['max_bridges'], 1)


if __name__ == '__main__':
    unittest.main()
