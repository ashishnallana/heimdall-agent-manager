"""Real hub billing smoke test. Set HEIMDALL_BILLING_TEST_BINARY to a built hub.

Uses a temporary database, random loopback port, and fake webhook secret. It
never contacts Paddle or an existing hub/bridge.
"""
from contextlib import closing
import base64
import struct
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
        with response:
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
        with closing(sqlite3.connect(self.database)) as conn, conn:
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
        with closing(sqlite3.connect(self.database)) as conn, conn:
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
        with closing(sqlite3.connect(self.database)) as conn, conn:
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
        with closing(sqlite3.connect(self.database)) as conn, conn:
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


    def test_bridge_plan_startup_hello_launch_upgrade_override_and_revoke(self):
        # Seed two already-enrolled bridges, representing an over-limit account
        # before migration/startup. A real salted token exercises hello auth.
        secret = '01' * 32
        salt = '02' * 16
        digest = hashlib.sha256((salt + ':' + secret).encode()).hexdigest()
        with closing(sqlite3.connect(self.database)) as conn, conn:
            for bridge_id, seen, version in [('brg_plan_old', '2026-10-20T00:00:00Z', '9.0.0'),
                                             ('brg_plan_new', '2026-10-21T00:00:00Z', '1.0.0')]:
                conn.execute("INSERT INTO bridges(bridge_id, owner_user_id, status, created_at, updated_at, last_seen_at, version) VALUES (?, 'alice', 'offline', '2026-10-01T00:00:00Z', '2026-10-21T00:00:00Z', ?, ?)",
                             (bridge_id, seen, version))
            conn.execute("INSERT INTO bridge_tokens(token_id, bridge_id, kind, token_hash, family_id, issued_at, expires_at) VALUES ('bat_plan', 'brg_plan_old', 'access', ?, 'family_plan', '2026-10-01T00:00:00Z', '2099-01-01T00:00:00Z')",
                         (f'sha256:v1:{salt}:{digest}',))
        self.process.terminate()
        self.process.wait(timeout=5)
        self.start_hub()

        def disabled(bridge_id):
            with closing(sqlite3.connect(self.database)) as conn, conn:
                return bool(conn.execute("SELECT plan_disabled_at FROM bridges WHERE bridge_id = ?", (bridge_id,)).fetchone()[0])

        self.assertTrue(disabled('brg_plan_old'), 'startup keeps recent activity over an older higher version')
        self.assertFalse(disabled('brg_plan_new'))
        status, rows = self.request('GET', '/api/v1/bridges', user='alice')
        self.assertEqual(status, 200)
        self.assertTrue(next(b for b in rows['data'] if b['bridge_id'] == 'brg_plan_old')['plan_disabled_at'])

        # A disabled hello receives a typed refusal before registry admission.
        with socket.create_connection(('127.0.0.1', self.port), timeout=5) as sock:
            key = base64.b64encode(b'plan-hello-test!x').decode()
            sock.sendall((f'GET /api/v1/bridge-ws HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n'
                          f'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
                          f'Sec-WebSocket-Version: 13\r\nAuthorization: Bearer hba_bat_plan.{secret}\r\n\r\n').encode())
            with sock.makefile('rb') as reader:
                self.assertIn(b'101', reader.readline())
                while reader.readline() != b'\r\n':
                    pass
                hello = json.dumps({'type': 'bridge_hello', 'protocol_version': 1, 'bridge_id': 'brg_plan_old'}).encode()
                mask = b'1234'
                self.assertLess(len(hello), 126)
                sock.sendall(bytes([0x81, 0x80 | len(hello)]) + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(hello)))
                opcode, size = reader.read(2)
                self.assertEqual(opcode & 0x0f, 1)
                size &= 0x7f
                if size == 126:
                    size = struct.unpack('!H', reader.read(2))[0]
                elif size == 127:
                    size = struct.unpack('!Q', reader.read(8))[0]
                frame = json.loads(reader.read(size))
                self.assertEqual(frame['payload']['code'], 'plan_limit_reached')
                self.assertEqual(frame['payload']['details']['allowed'], 1)
                self.assertEqual(frame['payload']['upgrade_path'], '/settings/account')
                close_opcode, close_size = reader.read(2)
                self.assertEqual(close_opcode, 0x88)
                closed = reader.read(close_size)
                self.assertEqual(struct.unpack('!H', closed[:2])[0], 4402)
                self.assertEqual(closed[2:].decode(), 'plan_limit_reached')

        status, agent = self.request('POST', '/api/v1/agents', {'name': 'Plan gate test'}, user='alice')
        self.assertEqual(status, 201)
        launch = {'agent_id': agent['data']['agent_id'], 'bridge_id': 'brg_plan_old', 'provider': 'codex', 'model': 'test'}
        status, refusal = self.request('POST', '/api/v1/agent-instances', launch, user='alice')
        self.assertEqual(status, 402)
        self.assertEqual(refusal['error']['code'], 'plan_limit_reached')
        self.assertEqual(refusal['error']['details']['current'], 2)
        # Ownership checks must still precede plan diagnostics.
        self.assertEqual(self.request('POST', '/api/v1/agent-instances', launch, user='bob')[0], 404)

        with closing(sqlite3.connect(self.database)) as conn, conn:
            conn.execute("INSERT INTO billing_checkouts(reference, user_id, plan_id, price_id, expires_at) VALUES ('server_reference', 'alice', 'hobbyist', 'pri_approved', '2099-01-01T00:00:00Z')")
        self.assertEqual(self.webhook('evt_bridge_upgrade', 'active', '2026-10-22T01:00:00Z')[0], 200)
        self.assertFalse(disabled('brg_plan_old'), 'webhook re-enables without reconnect or a billing-page request')
        self.assertEqual(self.request('POST', '/api/v1/agent-instances', launch, user='alice')[0], 409, 'after upgrade the ordinary offline check applies')
        self.assertEqual(self.webhook('evt_bridge_downgrade', 'canceled', '2026-10-22T02:00:00Z')[0], 200)
        self.assertTrue(disabled('brg_plan_old'))

        with closing(sqlite3.connect(self.database)) as conn, conn:
            conn.execute("UPDATE account_entitlements SET override_max_bridges = -1 WHERE user_id = 'alice'")
        self.assertEqual(self.request('GET', '/api/v1/account/billing', user='alice')[0], 200)
        self.assertFalse(disabled('brg_plan_old'), 'SQL override plus account refresh re-enables')
        with closing(sqlite3.connect(self.database)) as conn, conn:
            conn.execute("UPDATE account_entitlements SET override_max_bridges = NULL WHERE user_id = 'alice'")
        self.assertEqual(self.request('GET', '/api/v1/account/billing', user='alice')[0], 200)
        self.assertTrue(disabled('brg_plan_old'))
        self.assertEqual(self.request('POST', '/api/v1/bridges/brg_plan_new/revoke', {}, user='alice')[0], 200)
        self.assertFalse(disabled('brg_plan_old'), 'revocation frees the remaining slot')
        with closing(sqlite3.connect(self.database)) as conn, conn:
            self.assertEqual(conn.execute("SELECT revoked_at FROM bridge_tokens WHERE token_id = 'bat_plan'").fetchone()[0], '', 'disabling never revokes credentials')


if __name__ == '__main__':
    unittest.main()
