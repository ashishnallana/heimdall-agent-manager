"""Real hub billing smoke test. Set HEIMDALL_BILLING_TEST_BINARY to a built hub.

Uses a temporary database, random loopback port, and fake webhook secret. It
never contacts Paddle or an existing hub/bridge.
"""
from contextlib import ExitStack, closing
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
import sys
sys.path.insert(0, str(ROOT / 'tests'))
from hub_oidc_login import MockOIDC, login, session_headers, SESSION_COOKIE  # noqa: E402
UI_ORIGIN = 'http://127.0.0.1:5193'


class WebSocket:
    """Small RFC 6455 client for real-hub fixtures; no third-party dependency."""

    def __init__(self, port, path, session):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.reader = self.sock.makefile('rb')
        key = base64.b64encode(os.urandom(16)).decode()
        # A cookie-authenticated upgrade must carry Origin == ui_origin (CSRF).
        self.sock.sendall((
            f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
            f'Upgrade: websocket\r\nConnection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
            f'Cookie: {SESSION_COOKIE}={session}\r\nOrigin: {UI_ORIGIN}\r\n\r\n'
        ).encode())
        self.status = int(self.reader.readline().split()[1])
        headers = {}
        while True:
            line = self.reader.readline()
            if line == b'\r\n':
                break
            if not line:
                self.close()
                raise EOFError('hub closed during WebSocket handshake')
            name, value = line.decode().split(':', 1)
            headers[name.lower()] = value.strip()
        if self.status == 101:
            expected = base64.b64encode(hashlib.sha1(
                (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()
            ).digest()).decode()
            if headers.get('sec-websocket-accept') != expected:
                self.close()
                raise AssertionError('invalid WebSocket accept key')
            self.body = None
        else:
            self.body = json.loads(self.read_exact(int(headers['content-length'])))

    def read_exact(self, count):
        data = self.reader.read(count)
        if len(data) != count:
            raise EOFError('hub closed before the complete WebSocket frame')
        return data

    def frame(self):
        first, size = self.read_exact(2)
        opcode = first & 0x0f
        size &= 0x7f
        if size == 126:
            size = struct.unpack('!H', self.read_exact(2))[0]
        elif size == 127:
            size = struct.unpack('!Q', self.read_exact(8))[0]
        return opcode, self.read_exact(size)

    def json_frame(self):
        opcode, payload = self.frame()
        if opcode != 1:
            raise AssertionError(f'expected text frame; received opcode {opcode}')
        return json.loads(payload)

    def send(self, opcode, payload):
        mask = os.urandom(4)
        size = len(payload)
        header = bytes([0x80 | opcode])
        if size < 126:
            header += bytes([0x80 | size])
        elif size <= 65535:
            header += bytes([0x80 | 126]) + struct.pack('!H', size)
        else:
            header += bytes([0x80 | 127]) + struct.pack('!Q', size)
        self.sock.sendall(header + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(payload)))

    def close(self):
        self.reader.close()
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class AccountBillingHTTPTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='heimdall-billing-http-')
        self.addCleanup(self.directory.cleanup)
        self.hub_bin = os.environ.get('HEIMDALL_BILLING_TEST_BINARY')
        if not self.hub_bin or not Path(self.hub_bin).exists():
            build_root = Path.home() / '.cache' / 'heimdall-tests'
            build_root.mkdir(parents=True, exist_ok=True)
            build_dir = tempfile.TemporaryDirectory(prefix='billing-http-build-', dir=build_root)
            self.addCleanup(build_dir.cleanup)
            built = Path(build_dir.name) / 'ham-hub'
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
        self.addCleanup(self.log.close)
        self.addCleanup(self.stop_hub)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('HEIMDALL_PADDLE_') and key != 'HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS'}
        self.env.update(HEIMDALL_PADDLE_WEBHOOK_SECRET='test_only_secret', HEIMDALL_PADDLE_HOBBYIST_PRICE_ID='pri_approved', HEIMDALL_PADDLE_ENVIRONMENT='sandbox')
        # Users sign in through the real OIDC browser flow against a mock provider.
        self.mock = MockOIDC.start()
        self.addCleanup(self.mock.stop)
        self.env.update(self.mock.hub_env(self.base))
        self.sessions = {}
        self.start_hub()

    def start_hub(self):
        self.process = subprocess.Popen([self.hub_bin, '--listen', f'127.0.0.1:{self.port}', '--db', self.database, '--migrations-dir', '/nonexistent/billing-test-migrations', '--ui-origin', UI_ORIGIN, *getattr(self, 'hub_args', [])], env=self.env, stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(300):
            try:
                status, _ = self.request('GET', '/api/v1/health')
                if status == 200 and self.request('GET', '/api/v1/me', user='alice')[0] == 200:
                    return
            except OSError:
                pass
            if self.process.poll() is not None:
                self.fail('hub exited during startup:\n' + Path(self.log.name).read_text())
            time.sleep(0.05)
        self.fail('hub did not start:\n' + Path(self.log.name).read_text())

    def stop_hub(self):
        if hasattr(self, 'process') and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)

    def session(self, user):
        if user not in self.sessions:
            self.sessions[user] = login(self.base, user)
        return self.sessions[user]

    def request(self, method, path, data=None, user=None, extra=None):
        headers = {'Content-Type': 'application/json'}
        if user:
            headers.update(session_headers(self.session(user), UI_ORIGIN))
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


    def seed_terminals(self):
        """Durable rows only; no provider processes or existing bridges are used."""
        self.assertEqual(self.request('GET', '/api/v1/me', user='bob')[0], 200)
        for user in ('alice', 'bob'):
            status, agent = self.request('POST', '/api/v1/agents', {'name': 'Plan smoke'}, user=user)
            self.assertEqual(status, 201)
            with closing(sqlite3.connect(self.database)) as conn, conn:
                conn.execute("""INSERT INTO bridges(bridge_id, owner_user_id, status, created_at, updated_at)
                    VALUES (?, ?, 'offline', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')""",
                    (f'brg_{user}', user))
                conn.execute("""INSERT INTO agent_instances(agent_instance_id, owner_user_id, agent_id,
                    bridge_id, runtime_status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'running', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')""",
                    (f'inst_{user}', user, agent['data']['agent_id'], f'brg_{user}'))
                for kind in ('run', 'shell', 'server'):
                    conn.execute("""INSERT INTO shell_sessions(session_id, owner_user_id, bridge_id,
                        agent_instance_id, kind, cmd, status, started_at, created_at)
                        VALUES (?, ?, ?, ?, ?, 'test fixture', 'running',
                        '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')""",
                        (f'sh_{user}_{kind}', user, f'brg_{user}', f'inst_{user}', kind))

    def assert_plan_error(self, result, limit, allowed, current, label='Free'):
        status, body = result
        self.assertEqual(status, 402, body)
        error = body['error']
        self.assertEqual(error['code'], 'plan_limit_reached')
        details = error['details']
        self.assertEqual(details['limit'], limit)
        self.assertEqual(details['allowed'], allowed)
        self.assertEqual(details['current'], current)
        self.assertEqual(details['plan_label'], label)
        self.assertEqual(details['upgrade_path'], '/settings/account')

    def upgrade(self):
        with closing(sqlite3.connect(self.database)) as conn, conn:
            conn.execute("""INSERT INTO billing_checkouts(reference, user_id, plan_id, price_id, expires_at)
                VALUES ('server_reference', 'alice', 'hobbyist', 'pri_approved', '2099-01-01T00:00:00Z')""")
        self.assertEqual(self.webhook('evt_smoke_upgrade', 'active', '2026-10-22T01:00:00Z')[0], 200)

    def stream(self, path, user='alice'):
        return WebSocket(self.port, path, self.session(user))

    def assert_ready(self, stream, read_only):
        self.assertEqual(stream.status, 101, stream.body)
        frame = stream.json_frame()
        self.assertEqual(frame['type'], 'ready', frame)
        self.assertEqual(frame['read_only'], read_only)

    def test_terminal_rest_limits_and_upgrade(self):
        self.seed_terminals()
        mutations = [
            ('/api/v1/agent-instances/inst_alice/input', {'data': 'x'}),
            ('/api/v1/agent-instances/inst_alice/resize', {'rows': 24, 'cols': 80}),
            ('/api/v1/bridges/brg_alice/shells/sh_alice_run/input', {'data': 'x'}),
            ('/api/v1/bridges/brg_alice/shells/sh_alice_run/resize', {'rows': 24, 'cols': 80}),
            ('/api/v1/shells/sh_alice_run/input', {'data': 'x'}),
            ('/api/v1/shells/sh_alice_run/resize', {'rows': 24, 'cols': 80}),
            ('/api/v1/shells/sh_alice_run/signal', {'signal': 2}),
        ]
        for path, body in mutations:
            with self.subTest(path=path, plan='free'):
                self.assert_plan_error(self.request('POST', path, body, user='alice'),
                                       'terminal_input_enabled', 0, 1)
        # Hub user tokens were removed: a hut_ bearer is refused before any plan check.
        status, refused = self.request('POST', mutations[0][0], mutations[0][1], extra={'Authorization': 'Bearer hut_removed'})
        self.assertEqual(status, 401, refused)
        self.upgrade()
        for path, body in mutations:
            with self.subTest(path=path, plan='hobbyist'):
                status, response = self.request('POST', path, body, user='alice')
                # No live bridge in this fixture: prove the real operation is reached,
                # rather than treating an arbitrary non-402 (e.g. 500) as success.
                self.assertEqual(status, 409, response)
                self.assertEqual(response['error']['code'], 'bridge_offline')

    def test_user_shell_create_restart_and_existing_stream_after_upgrade(self):
        self.seed_terminals()
        actions = [
            ('/api/v1/bridges/brg_alice/shells', {'kind': kind, 'cmd': 'echo plan smoke', **({'chain_id': 'chain_plan_smoke'} if kind == 'server' else {})})
            for kind in ('shell', 'server')
        ] + [
            (f'/api/v1/shells/sh_alice_{kind}/restart', {})
            for kind in ('shell', 'server')
        ]
        for path, body in actions:
            with self.subTest(path=path, body=body, plan='free'):
                self.assert_plan_error(self.request('POST', path, body, user='alice'),
                                       'shells_enabled', 0, 1)
        with self.stream('/api/v1/shells/sh_alice_shell/stream') as stream:
            self.assert_plan_error((stream.status, stream.body), 'shells_enabled', 0, 1)
        self.upgrade()
        with self.stream('/api/v1/shells/sh_alice_shell/stream') as stream:
            self.assert_ready(stream, False)
        for path, body in actions:
            with self.subTest(path=path, body=body, plan='hobbyist'):
                status, response = self.request('POST', path, body, user='alice')
                self.assertEqual(status, 409, response)
                self.assertEqual(response['error']['code'], 'bridge_offline')

    def test_mixed_stream_cap_owner_isolation_disconnect_and_webhook_upgrade(self):
        self.seed_terminals()
        agent_path = '/api/v1/agent-instances/inst_alice/stream'
        shell_path = '/api/v1/shells/sh_alice_run/stream'
        with ExitStack() as stack:
            first = stack.enter_context(self.stream(agent_path))
            second = stack.enter_context(self.stream(shell_path))
            self.assert_ready(first, True)
            self.assert_ready(second, True)
            for path in (agent_path, shell_path):
                with self.subTest(path=path), self.stream(path) as refused:
                    self.assertEqual(refused.status, 101)
                    frame = refused.json_frame()
                    self.assertEqual(frame['type'], 'error')
                    self.assert_plan_error((402, {'error': frame}), 'max_concurrent_streams', 2, 2)
                    opcode, payload = refused.frame()
                    self.assertEqual(opcode, 8)
                    self.assertEqual(struct.unpack('!H', payload[:2])[0], 4402)
            for path in ('/api/v1/agent-instances/inst_alice/pane', '/api/v1/shells/sh_alice_run/pane'):
                self.assert_plan_error(self.request('GET', path, user='alice'), 'max_concurrent_streams', 2, 2)
            with self.stream('/api/v1/agent-instances/inst_bob/stream', user='bob') as other:
                self.assert_ready(other, True)

            first.close()
            # Detach runs on the server reader thread; wait for its effect through
            # the real API rather than sleeping and assuming cleanup has finished.
            for _ in range(50):
                replacement = self.stream(agent_path)
                frame = replacement.json_frame()
                if frame['type'] == 'ready':
                    stack.enter_context(replacement)
                    self.assertTrue(frame['read_only'])
                    break
                replacement.close()
                time.sleep(0.02)
            else:
                self.fail('disconnect did not free the user stream slot')

            # Both original slots remain occupied. Webhook invalidation must permit
            # more than two attaches immediately, without an Account-page refresh.
            self.upgrade()
            for path in (agent_path, shell_path, agent_path):
                upgraded = stack.enter_context(self.stream(path))
                self.assert_ready(upgraded, False)


    def test_paid_override_refusals_keep_the_effective_plan_label(self):
        self.seed_terminals()
        self.upgrade()
        with closing(sqlite3.connect(self.database)) as conn, conn:
            conn.execute("""UPDATE account_entitlements SET override_terminal_input_enabled = 0,
                override_shells_enabled = 0, override_max_concurrent_streams = 0 WHERE user_id = 'alice'""")
        status, billing = self.request('GET', '/api/v1/account/billing', user='alice')
        self.assertEqual(status, 200)
        self.assertEqual(billing['data']['plan_label'], 'Hobbyist')
        for path, body, limit in [
            ('/api/v1/agent-instances/inst_alice/input', {'data': 'x'}, 'terminal_input_enabled'),
            ('/api/v1/bridges/brg_alice/shells', {'kind': 'shell'}, 'shells_enabled'),
        ]:
            self.assert_plan_error(self.request('POST', path, body, user='alice'),
                                   limit, 0, 1, label='Hobbyist')
        with self.stream('/api/v1/agent-instances/inst_alice/stream') as refused:
            self.assertEqual(refused.status, 101)
            self.assert_plan_error((402, {'error': refused.json_frame()}),
                                   'max_concurrent_streams', 0, 0, label='Hobbyist')

    def test_bridge_approval_pending_cap_reuse_and_upgrade(self):
        # The helper uses the actual UI signing/pairing code against this hub.
        # Existing bridge smoke below separately covers startup/hello/launch/revoke.
        with closing(sqlite3.connect(self.database)) as conn, conn:
            conn.execute("""INSERT INTO billing_checkouts(reference, user_id, plan_id, price_id, expires_at)
                VALUES ('server_reference', 'alice', 'hobbyist', 'pri_approved', '2099-01-01T00:00:00Z')""")
        result = subprocess.run(
            ['node', '--import', './tests/helpers/vaultEndpointHarness.ts',
             'tests/e2e/plan_bridge_approval.mjs', self.base, self.database, UI_ORIGIN],
            cwd=ROOT, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS bridge approval cap, pending count, reuse, upgrade', result.stdout)

    def test_billing_persistence_webhooks_and_authentication(self):
        self.assertEqual(self.request('GET', '/api/v1/account/billing')[0], 401)
        # First OIDC sign-in (startup probe) persists defaults before opening Account.
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
        self.assertEqual(self.request('GET', '/api/v1/account/billing', extra={'Authorization': 'Bearer hut_removed'})[0], 401)
        # A native OIDC bearer is accepted, but account routes need the v2 device proof.
        bearer = {'Authorization': 'Bearer ' + self.mock.access_token('alice', 'mock-alice')}
        self.assertEqual(self.request('GET', '/api/v1/account/billing', extra=bearer)[0], 401)
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
            # An orphan sorts before alice and cannot acquire billing defaults.
            # It must neither abort startup nor prevent healthy-owner reconciliation.
            conn.execute("INSERT INTO bridges(bridge_id, owner_user_id, status, created_at, updated_at) VALUES ('brg_orphan', 'aaa_orphan', 'offline', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')")
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
