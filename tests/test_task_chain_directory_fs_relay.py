#!/usr/bin/env python3
"""Regression test for REQ-BE-TASK-CHAIN-DIRECTORY-FS-RELAY:
Backend filesystem relay and endpoints for task chain directories.
Tests:
1. Static code verification (handlers, router wiring, sandboxing, and service procs).
2. Live Hub REST API and WebSocket bridge relay:
   - Authentication guards (require_auth_any).
   - Task chain directory resolution and bridge routing.
   - Bridge runtime command relay sandboxed to dir.path.
   - All directory fs endpoints: list, read file, write file, batch write, create file, mkdir, move, delete, quick-open.
"""

import base64
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from hub_oidc_login import MockOIDC, login, session_headers  # noqa: E402
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def require(ok: bool, message: str) -> None:
    if not ok:
        print(f"FAILED: {message}", file=sys.stderr)
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def encode_ws_frame(payload: str, is_client: bool = True) -> bytes:
    data = payload.encode("utf-8")
    length = len(data)
    frame = bytearray()
    frame.append(0x81)  # FIN + text opcode (1)
    mask_bit = 0x80 if is_client else 0x00
    if length <= 125:
        frame.append(mask_bit | length)
    elif length <= 65535:
        frame.append(mask_bit | 126)
        frame.extend(struct.pack("!H", length))
    else:
        frame.append(mask_bit | 127)
        frame.extend(struct.pack("!Q", length))

    if is_client:
        mask_key = os.urandom(4)
        frame.extend(mask_key)
        masked_data = bytearray(length)
        for i in range(length):
            masked_data[i] = data[i] ^ mask_key[i % 4]
        frame.extend(masked_data)
    else:
        frame.extend(data)
    return bytes(frame)


def decode_ws_frame(raw: bytes) -> tuple[str, bytes]:
    if len(raw) < 2:
        return "", raw
    masked = bool(raw[1] & 0x80)
    length = raw[1] & 0x7F
    offset = 2
    if length == 126:
        if len(raw) < 4:
            return "", raw
        length = struct.unpack("!H", raw[2:4])[0]
        offset = 4
    elif length == 127:
        if len(raw) < 10:
            return "", raw
        length = struct.unpack("!Q", raw[2:10])[0]
        offset = 10

    if masked:
        if len(raw) < offset + 4 + length:
            return "", raw
        mask_key = raw[offset:offset + 4]
        offset += 4
        payload_bytes = bytearray(length)
        for i in range(length):
            payload_bytes[i] = raw[offset + i] ^ mask_key[i % 4]
        remainder = raw[offset + length:]
        return payload_bytes.decode("utf-8", errors="replace"), remainder
    else:
        if len(raw) < offset + length:
            return "", raw
        payload_bytes = raw[offset:offset + length]
        remainder = raw[offset + length:]
        return payload_bytes.decode("utf-8", errors="replace"), remainder


def build_odin_pkg(pkg: str, out_path: Path) -> None:
    import shutil
    odin = os.environ.get("ODIN") or shutil.which("odin")
    res = None
    if odin and os.environ.get("IN_NIX_SHELL"):
        res = subprocess.run([odin, "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    if res is None or res.returncode != 0:
        res = subprocess.run(["nix", "develop", "--command", "odin", "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    require(res.returncode == 0, f"build failed for {pkg}: {res.stderr}")


def test_live_directory_fs_relay() -> None:
    import shutil
    import tempfile
    print("Testing live Hub task chain directory fs relay with mock bridge...")
    tmp_dir = Path(tempfile.mkdtemp(prefix="ham-test-dir-fs-"))
    hub_bin = tmp_dir / "test_hub"
    print("Building test_hub binary...")
    if os.environ.get("HEIMDALL_TEST_HUB_BIN"):
        hub_bin = Path(os.environ["HEIMDALL_TEST_HUB_BIN"])
    else:
        build_odin_pkg("src/hub", hub_bin)

    port = find_free_port()
    db_path = str(tmp_dir / f"ham-test-dir-fs-{port}.db")

    migrations_dir = str(ROOT / "src/hub/repository/sqlite/migrations")
    # Users sign in only with OIDC: a mock provider and a real browser session.
    mock = MockOIDC.start()
    hub_proc = subprocess.Popen(
        [str(hub_bin), "--listen", f"127.0.0.1:{port}", "--db", db_path, "--ui-origin", f"http://127.0.0.1:{port}"],
        env={**os.environ, **mock.hub_env(f"http://127.0.0.1:{port}")},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    ws_sock = None
    bridge_running = True

    try:
        # Wait for Hub to be ready
        ready = False
        base_url = f"http://127.0.0.1:{port}"
        for _ in range(300):
            try:
                with urllib.request.urlopen(f"{base_url}/api/v1/health", timeout=1) as resp:
                    if resp.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.1)

        require(ready, "Hub failed to start up within timeout")
        user_tok = login(base_url, "dirtest")  # browser session id

        def api_request(method: str, path: str, payload=None, token=user_tok) -> tuple[int, dict]:
            url = f"{base_url}{path}"
            data = json.dumps(payload).encode("utf-8") if payload is not None else None
            req = urllib.request.Request(url, data=data, method=method)
            if token:
                for k, v in session_headers(token, base_url).items():
                    req.add_header(k, v)
            req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return resp.status, json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8")
                try:
                    parsed = json.loads(body)
                except Exception:
                    parsed = {"raw": body}
                return e.code, parsed

        # 1. Create task chain
        status, data = api_request("POST", "/api/v1/task-chains", {"title": "Directory FS Chain", "kind": "team_work"})
        require(status == 201 or status == 200, f"failed to create chain: {status} {data}")
        chain_id = data["data"]["chain_id"]

        # 2. Add directory
        target_dir_path = "/tmp/sandboxed_task_chain_dir"
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories", {
            "path": target_dir_path,
        })
        require(status == 201, f"failed to add directory: {status} {data}")
        dir_id = data["data"]["directory_id"]

        # 3. Test unauthenticated request -> 401 Unauthorized
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs", token=None)
        require(status == 401, f"expected 401 for unauthenticated request, got {status} {data}")

        # 4. Test non-existent directory -> 404 Not Found
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/dir_not_exist/fs")
        require(status == 404, f"expected 404 for non-existent directory, got {status}")

        # 5. Test single directory GET endpoint -> 200 OK
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}")
        require(status == 200, f"expected 200 for single directory get, got {status} {data}")
        require(data["data"]["directory_id"] == dir_id, "directory_id mismatch")
        require(data["data"]["path"] == target_dir_path, "directory path mismatch")

        # 6. Test bridge offline error when no bridge is online
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs")
        require(status == 400 or status == 503, f"expected bridge offline error (400/503), got {status} {data}")

        # 7. Enroll a bridge through the BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9).
        #
        # The old pair -- POST /api/v1/bridge-enrollments for a one-time token, then
        # POST /api/v1/bridges/enroll to exchange it -- is deleted and both 404 now.
        #
        # Three hard refusals to respect: bridge_public_key must be a 130-char
        # lowercase-hex uncompressed P-256 point; bridge_key_fingerprint must NOT be
        # sent (the Hub derives it and rejects a disagreeing one); and PKCE is
        # mandatory and S256-only, so the precomputed pair below is required.
        #
        # token=None on authorize and token: it is an ANONYMOUS request by the bridge.
        # The user's browser session authenticates only the approval, which binds the
        # bridge's owner.
        status, data = api_request("POST", "/api/v1/device/authorize", {
            "client": "ham-bridge",
            "device_label": "mock-bridge-host",
            "os": "linux",
            "os_user": "tester",
            "bridge_public_key": "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
            "code_challenge": "J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI",
            "code_challenge_method": "S256",
        }, token=None)
        require(status == 200, f"device authorize failed: {status} {data}")
        user_code = data["data"]["user_code"]
        device_code = data["data"]["device_code"]

        status, data = api_request("POST", "/api/v1/device/approve", {"user_code": user_code, "approve": True})
        require(status == 200, f"device approve failed: {status} {data}")

        status, data = api_request("POST", "/api/v1/device/token", {
            "device_code": device_code,
            "code_verifier": "heimdall-req-impl-6-test-code-verifier-aaaa",
        }, token=None)
        require(status == 200, f"device token failed: {status} {data}")
        bridge_id = data["data"]["bridge_id"]
        # The credential is the EXPIRING access token now, not a non-expiring one.
        bridge_token = data["data"]["access_token"]

        # Capabilities are REPORTED at connect, not declared at enrollment: the device
        # flow has no capabilities field, because the Hub records only what the
        # approving human confirmed. The mock bridge below is what reports them.

        # 8. Update directory with enrolled bridge_id
        status, data = api_request("PATCH", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}", {
            "bridge_id": bridge_id,
        })
        require(status == 200, f"patch directory failed: {status} {data}")
        require(data["data"]["bridge_id"] == bridge_id, "bridge_id was not updated on directory")

        # 9. Connect mock bridge over WebSocket (/api/v1/bridge-ws)
        ws_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ws_sock.connect(("127.0.0.1", port))
        raw_key = base64.b64encode(os.urandom(16)).decode()
        ws_handshake = (
            f"GET /api/v1/bridge-ws HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {raw_key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {bridge_token}\r\n\r\n"
        )
        ws_sock.sendall(ws_handshake.encode())
        resp_hdr = b""
        while b"\r\n\r\n" not in resp_hdr:
            chunk = ws_sock.recv(1024)
            require(bool(chunk), "connection closed during ws handshake")
            resp_hdr += chunk
        require(b"101 Switching Protocols" in resp_hdr, "WebSocket upgrade failed")

        # Send bridge_hello
        hello_msg = json.dumps({
            "type": "bridge_hello",
            "protocol_version": 2,
            "bridge_id": bridge_id,
            "hostname": "mock-bridge-host",
            "capabilities": [{"provider": "claude", "tiers": ["normal"], "default_tier": "normal"}],
        })
        ws_sock.sendall(encode_ws_frame(hello_msg, is_client=True))

        # Background thread to handle incoming Hub filesystem commands and reply
        received_commands = []
        lock = threading.Lock()

        def mock_bridge_worker():
            buf = b""
            while bridge_running:
                try:
                    chunk = ws_sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while True:
                        frame_text, remainder = decode_ws_frame(buf)
                        if not frame_text and remainder == buf:
                            break
                        buf = remainder
                        if not frame_text:
                            continue
                        try:
                            cmd_json = json.loads(frame_text)
                        except Exception:
                            continue

                        cmd_type = cmd_json.get("type", "")
                        cmd_id = cmd_json.get("command_id", "")
                        with lock:
                            received_commands.append(cmd_json)

                        # Handle and reply to filesystem commands
                        if cmd_type == "fs_list_dir":
                            reply = json.dumps({
                                "type": "fs_list_dir_result",
                                "command_id": cmd_id,
                                "ok": True,
                                "path": cmd_json.get("path", ""),
                                "entries": [
                                    {"name": "file1.txt", "type": "file", "size": 128},
                                    {"name": "subdir", "type": "directory", "size": 0},
                                ],
                            })
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_read_file":
                            reply = json.dumps({
                                "type": "fs_read_file_result",
                                "command_id": cmd_id,
                                "ok": True,
                                "path": cmd_json.get("path", ""),
                                "content": "Hello from sandboxed task chain directory!",
                            })
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_create_file":
                            reply = json.dumps({"type": "fs_create_file_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_write_file":
                            reply = json.dumps({"type": "fs_write_file_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_batch_write":
                            reply = json.dumps({"type": "fs_batch_write_result", "command_id": cmd_id, "ok": True, "saved": []})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_make_dir":
                            reply = json.dumps({"type": "fs_make_dir_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_move":
                            reply = json.dumps({"type": "fs_move_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_delete":
                            reply = json.dumps({"type": "fs_delete_result", "command_id": cmd_id, "ok": True})
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                        elif cmd_type == "fs_find_files":
                            reply = json.dumps({
                                "type": "fs_find_files_result",
                                "command_id": cmd_id,
                                "ok": True,
                                "matches": ["file1.txt", "subdir/inner.txt"],
                            })
                            ws_sock.sendall(encode_ws_frame(reply, is_client=True))
                except Exception:
                    break

        th = threading.Thread(target=mock_bridge_worker, daemon=True)
        th.start()

        # Give bridge handshake a moment to register as live
        time.sleep(0.3)

        # 10. Test GET /api/v1/task-chains/*/directories/*/fs (list dir)
        print("Testing GET /fs (list dir)...")
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs")
        require(status == 200, f"fs list dir failed: {status} {data}")
        require("entries" in data["data"], "data must contain entries")
        require(any(e["name"] == "file1.txt" for e in data["data"]["entries"]), "entries missing file1.txt")

        # Verify command received by mock bridge had root sandboxed to dir.path
        with lock:
            last_cmd = received_commands[-1]
            require(last_cmd["type"] == "fs_list_dir", f"expected fs_list_dir, got {last_cmd}")
            require(last_cmd["root"] == target_dir_path, f"sandbox root mismatch: {last_cmd['root']} != {target_dir_path}")

        # 11. Test GET /api/v1/task-chains/*/directories/*/fs/file (read file)
        print("Testing GET /fs/file (read file)...")
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/file?path=file1.txt")
        require(status == 200, f"fs read file failed: {status} {data}")
        require(data["data"]["content"] == "Hello from sandboxed task chain directory!", f"content mismatch: {data}")

        with lock:
            last_cmd = received_commands[-1]
            require(last_cmd["type"] == "fs_read_file", f"expected fs_read_file, got {last_cmd}")
            require(last_cmd["root"] == target_dir_path, f"sandbox root mismatch: {last_cmd['root']}")
            require(last_cmd["path"] == "file1.txt", f"path mismatch: {last_cmd['path']}")

        # 12. Test GET /api/v1/task-chains/*/directories/*/fs/quick-open (quick-open)
        print("Testing GET /fs/quick-open...")
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/quick-open?query=file")
        require(status == 200, f"fs quick-open failed: {status} {data}")
        require("file1.txt" in data["data"]["matches"], f"matches mismatch: {data}")

        # 13. Test POST /api/v1/task-chains/*/directories/*/fs/file (create file)
        print("Testing POST /fs/file (create file)...")
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/file", {"path": "new.txt"})
        require(status == 200, f"fs create file failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_create_file", "expected fs_create_file")

        # 14. Test PUT /api/v1/task-chains/*/directories/*/fs/file (write file)
        print("Testing PUT /fs/file (write file)...")
        status, data = api_request("PUT", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/file", {"path": "new.txt", "content": "test content"})
        require(status == 200, f"fs write file failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_write_file", "expected fs_write_file")
            require(received_commands[-1]["content"] == "test content", "content mismatch")

        # 15. Test PUT /api/v1/task-chains/*/directories/*/fs/files (batch write)
        print("Testing PUT /fs/files (batch write)...")
        status, data = api_request("PUT", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/files", {
            "files": [{"path": "b1.txt", "content": "c1"}, {"path": "b2.txt", "content": "c2"}]
        })
        require(status == 200, f"fs batch write failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_batch_write", "expected fs_batch_write")

        # 16. Test POST /api/v1/task-chains/*/directories/*/fs/dir (mkdir)
        print("Testing POST /fs/dir (mkdir)...")
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/dir", {"path": "new_folder"})
        require(status == 200, f"fs mkdir failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_make_dir", "expected fs_make_dir")

        # 17. Test POST /api/v1/task-chains/*/directories/*/fs/move (move/rename)
        print("Testing POST /fs/move (move)...")
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs/move", {"from": "a.txt", "to": "b.txt"})
        require(status == 200, f"fs move failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_move", "expected fs_move")

        # 18. Test DELETE /api/v1/task-chains/*/directories/*/fs (delete)
        print("Testing DELETE /fs (delete)...")
        status, data = api_request("DELETE", f"/api/v1/task-chains/{chain_id}/directories/{dir_id}/fs?path=b.txt")
        require(status == 200, f"fs delete failed: {status} {data}")
        with lock:
            require(received_commands[-1]["type"] == "fs_delete", "expected fs_delete")

        print("End-to-end directory filesystem relay tests PASSED successfully.")

    finally:
        bridge_running = False
        if ws_sock:
            try:
                ws_sock.close()
            except Exception:
                pass
        mock.stop()
        hub_proc.terminate()
        try:
            hub_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            hub_proc.kill()
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    test_live_directory_fs_relay()
    print("\nALL DIRECTORY FS RELAY TESTS PASSED! (0 errors)")
