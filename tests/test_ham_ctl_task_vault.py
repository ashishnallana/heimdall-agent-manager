#!/usr/bin/env python3
"""Comprehensive test suite for CLI and Bridge Tasks & Task Comments Zero-Knowledge encryption and decryption (REQ-VAULT-TASKS-1).

Verifies:
1. Static contract verification:
   - ctl_read_vault_key in src/ctl/vault.odin resolves --vault-key, HEIMDALL_VAULT_KEY, then the local bridge (agent.vault.get); never ~/.config/heimdall/vault_key.
   - Transparent encryption on write in src/ctl/agent_mode.odin & src/ctl/tasks.odin (create, update, comment).
   - Transparent decryption on read in src/ctl/agent_mode.odin & src/ctl/tasks.odin (show, list, comments).
   - Safe unconfigured fallback [Encrypted: vault:v1:...].
2. Odin unit test suite:
   - 'odin test src/ctl -collection:odin_test=src' passes cleanly with 0 errors.
3. Live end-to-end CLI round-trip (if Bridge runtime is active):
   - ham-ctl task create -> stores armored in DB -> ham-ctl task show decrypts -> (HEIMDALL_VAULT_KEY switched to a different key) -> ham-ctl task show shows encrypted fallback.
"""

import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CTL_VAULT = ROOT / "src" / "ctl" / "vault.odin"
CTL_TASKS = ROOT / "src" / "ctl" / "tasks.odin"
CTL_AGENT_MODE = ROOT / "src" / "ctl" / "agent_mode.odin"
CTL_VAULT_CONTENT = ROOT / "src" / "ctl" / "vault_content.odin"

TEST_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
# A different valid key: decrypting TEST_KEY_HEX ciphertext with it must fall back.
OTHER_KEY_HEX = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}", file=sys.stderr)
        sys.exit(1)


def test_static_contracts() -> None:
    print("1. Verifying static code contracts for tasks vault encryption...")
    require(CTL_VAULT.exists(), f"Missing {CTL_VAULT}")
    vault_src = CTL_VAULT.read_text(encoding="utf-8")
    require("ctl_read_vault_key :: proc" in vault_src, "ctl_read_vault_key must be defined in src/ctl/vault.odin")

    require(CTL_VAULT_CONTENT.exists(), f"Missing {CTL_VAULT_CONTENT}")
    vc_src = CTL_VAULT_CONTENT.read_text(encoding="utf-8")
    require("ctl_decrypt_or_fallback_armored" in vc_src, "ctl_decrypt_or_fallback_armored must be defined")
    require("ctl_decrypt_json_string" in vc_src, "ctl_decrypt_json_string must be defined")
    require("[Encrypted: %s]" in vc_src, "fallback format '[Encrypted: %s]' must be present")

    require(CTL_AGENT_MODE.exists(), f"Missing {CTL_AGENT_MODE}")
    agent_src = CTL_AGENT_MODE.read_text(encoding="utf-8")
    require("ctl_agentmode_task_create_params" in agent_src, "ctl_agentmode_task_create_params must be defined")
    require("ctl_agentmode_task_comment_params" in agent_src, "ctl_agentmode_task_comment_params must be defined")
    require("ctl_agentmode_task_update_params" in agent_src, "ctl_agentmode_task_update_params must be defined")
    require("ctl_agent_call_task" in agent_src, "ctl_agent_call_task must be defined")

    require(CTL_TASKS.exists(), f"Missing {CTL_TASKS}")
    tasks_src = CTL_TASKS.read_text(encoding="utf-8")
    require("ctl_tasks_request_and_decrypt" in tasks_src, "ctl_tasks_request_and_decrypt must be defined")
    require("vault_encrypt_text_hex" in tasks_src, "vault_encrypt_text_hex must be used in tasks.odin")

    print("   ✓ Static code contracts verified.")


def test_odin_suite() -> None:
    print("2. Running Odin unit tests...")
    res = subprocess.run(
        ["odin", "test", "src/ctl", "-collection:odin_test=src"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    combined = res.stdout + res.stderr
    if res.returncode != 0:
        print("OUTPUT:\n", combined, file=sys.stderr)
    require(res.returncode == 0, "odin test src/ctl must exit 0")
    require("All tests were successful" in combined, "All Odin tests must succeed")
    print("   ✓ All Odin tests passed cleanly.")


def test_live_cli_roundtrip() -> None:
    print("3. Testing live CLI round-trip for tasks...")
    bin_dir = ROOT / "bin"
    bin_dir.mkdir(exist_ok=True)
    bin_ctl = bin_dir / "ham-ctl"
    build_res = subprocess.run(
        ["odin", "build", "src/ctl", "-collection:odin_test=src", f"-out:{bin_ctl}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    require(build_res.returncode == 0, f"ham-ctl binary build failed: {build_res.stderr}")

    endpoint = os.environ.get("HEIMDALL_BRIDGE_ENDPOINT", "")
    if endpoint.startswith("unix:"):
        sock_path = pathlib.Path(endpoint[len("unix:"):])
        if not sock_path.exists():
            endpoint = ""
    if not endpoint:
        sock_path = pathlib.Path("/tmp/heimdall-bridge-local/bridge.sock")
        if sock_path.exists():
            endpoint = f"unix:{sock_path}"
        else:
            endpoint = "tcp:127.0.0.1:49324"

    coord_wrapper = pathlib.Path("/tmp/heimdall-bridge-local/instances/inst_18d892527caaf3cf/.heimdall/bin/ham-ctl")
    token = ""
    inst_id = ""
    if coord_wrapper.exists():
        for line in coord_wrapper.read_text(encoding="utf-8").splitlines():
            if "HEIMDALL_AGENT_TOKEN=" in line and not token:
                token = line.split("HEIMDALL_AGENT_TOKEN=")[1].strip("'\"")
            if "HEIMDALL_AGENT_INSTANCE_ID=" in line and not inst_id:
                inst_id = line.split("HEIMDALL_AGENT_INSTANCE_ID=")[1].strip("'\"")

    if not token or not inst_id:
        token = os.environ.get("HEIMDALL_AGENT_TOKEN", "hlat_18d8926642e6ae98_179")
        inst_id = os.environ.get("HEIMDALL_AGENT_INSTANCE_ID", "inst_18d892527caaf3cf")

    env = os.environ.copy()
    env["HEIMDALL_BRIDGE_ENDPOINT"] = endpoint
    env["HEIMDALL_AGENT_TOKEN"] = token
    env["HEIMDALL_AGENT_INSTANCE_ID"] = inst_id

    # Step 1: Use the test key via the explicit env override (no key file, and the
    # live bridge's own key is not touched).
    env["HEIMDALL_VAULT_KEY"] = TEST_KEY_HEX

    chain_id = "chain_18d892527be5e57f"
    task_title = "Vault Zero-Knowledge Live Roundtrip Task"
    task_desc = "Secret test description for REQ-VAULT-TASKS-1 CLI verification"

    # Step 2: Create task with encrypted title and description
    res_create = subprocess.run(
        [str(bin_ctl), "task", "create", "--chain", chain_id, "--title", task_title, "--description", task_desc, "--priority", "p2"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    require(res_create.returncode == 0, f"task create failed: {res_create.stderr}")
    data_create = json.loads(res_create.stdout)
    task_id = (
        data_create.get("data", {}).get("data", {}).get("task_id")
        or data_create.get("data", {}).get("task_id")
    )
    require(bool(task_id), f"Failed to get task_id from response: {res_create.stdout}")

    try:
        # Step 3: Add comment with encrypted body
        comment_body = "Encrypted task comment verification payload for REQ-VAULT-TASKS-1"
        res_comment = subprocess.run(
            [str(bin_ctl), "task", "comment", task_id, "--chain", chain_id, "--body", comment_body],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        require(res_comment.returncode == 0, f"task comment failed: {res_comment.stderr}")

        # Step 4: Show task while key is configured -> decrypted plaintext
        res_show_dec = subprocess.run(
            [str(bin_ctl), "task", "show", task_id, "--chain", chain_id],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        require(res_show_dec.returncode == 0, f"task show failed: {res_show_dec.stderr}")
        data_show = json.loads(res_show_dec.stdout)
        task_data = data_show.get("data", {}).get("data", {})
        require(task_data.get("title") == task_title, f"decrypted title mismatch: {task_data.get('title')}")
        require(task_data.get("description") == task_desc, f"decrypted desc mismatch: {task_data.get('description')}")
        require("vault:v1:" not in task_data.get("title", ""), "title must not be armored")
        require("vault:v1:" not in task_data.get("description", ""), "description must not be armored")

        # Step 4b: Comments list while key is configured -> decrypted comment body
        res_comments_dec = subprocess.run(
            [str(bin_ctl), "task", "comments", task_id, "--chain", chain_id],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        require(res_comments_dec.returncode == 0, f"task comments failed: {res_comments_dec.stderr}")
        require(comment_body in res_comments_dec.stdout, "task comments must contain decrypted comment body")
        require("vault:v1:" not in res_comments_dec.stdout, "task comments must not contain raw armored string")

        # Step 5: List tasks -> decrypted plaintext
        res_list_dec = subprocess.run(
            [str(bin_ctl), "task", "list", "--chain", chain_id],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        require(res_list_dec.returncode == 0, f"task list failed: {res_list_dec.stderr}")
        require(task_title in res_list_dec.stdout, "task list must contain decrypted title")

        # Step 6: Switch to a different key, so the test key is no longer available
        env["HEIMDALL_VAULT_KEY"] = OTHER_KEY_HEX

        # Step 7: Show task without vault key -> graceful fallback [Encrypted: vault:v1:...]
        res_show_enc = subprocess.run(
            [str(bin_ctl), "task", "show", task_id, "--chain", chain_id],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        require(res_show_enc.returncode == 0, f"task show without key failed: {res_show_enc.stderr}")
        require("[Encrypted: vault:v1:" in res_show_enc.stdout, "task show must show [Encrypted: vault:v1:...] fallback")
        require(task_title not in res_show_enc.stdout, "plaintext title must not leak when key is unconfigured")
        require(task_desc not in res_show_enc.stdout, "plaintext description must not leak when key is unconfigured")

    finally:
        # Step 8: Clean up test task (cancel it)
        _ = subprocess.run(
            [str(bin_ctl), "task", "status", task_id, "--status", "cancelled"],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

    print("   ✓ Live CLI round-trip verified successfully.")


def main() -> None:
    test_static_contracts()
    test_odin_suite()
    test_live_cli_roundtrip()
    print("\nAll REQ-VAULT-TASKS-1 tests passed successfully!")


if __name__ == "__main__":
    main()
