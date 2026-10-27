#!/usr/bin/env python3
"""Record full automated verification without treating missing tests as success."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--group", choices=["odin", "ui", "misc"], required=True)
parser.add_argument("--out-dir", required=True)
parser.add_argument("--resume", action="store_true", help="Keep recorded outcomes and run only unfinished checks")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = Path(args.out_dir).expanduser().resolve() / args.group
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env.pop("HEIMDALL_AGENT_TOKEN", None)
env.pop("HEIMDALL_AGENT_INSTANCE_ID", None)
results_path = out / "results.json"
rows = json.loads(results_path.read_text()) if args.resume and results_path.exists() else []
recorded = {row["label"] for row in rows}

def run(label, command, timeout=900, expects_tests=False):
    if label in recorded:
        print("RECORDED " + label, flush=True)
        return
    log = out / (re.sub(r"[^a-zA-Z0-9_-]", "_", label) + ".log")
    print("START " + label, flush=True)
    started = time.monotonic()
    with log.open("w") as stream:
        try:
            process = subprocess.Popen(command, cwd=root, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code = 124
    body = log.read_text(errors="replace")
    clean = re.sub(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))", "", body)
    counts = re.findall(r"Finished (\d+) tests?", clean)
    if not counts:
        counts = re.findall(r"(?:ℹ|#) tests (\d+)", clean)
    missing = expects_tests and not counts
    row = dict(label=label, command=command, exit_code=code,
               passed=code == 0 and not missing, seconds=round(time.monotonic()-started, 2),
               tests=sum(map(int, counts)), missing_summary=missing, log=str(log))
    rows.append(row)
    results_path.write_text(json.dumps(rows, indent=2) + "\n")
    print(("PASS " if row["passed"] else "FAIL ") + label +
          f" exit={code} tests={row['tests']} seconds={row['seconds']}", flush=True)

if args.group == "odin":
    packages = sorted({str(p.parent.relative_to(root)) for p in (root/"src").rglob("*test.odin")})
    # Longest/lifetime-sensitive suites first; each package is serialized internally.
    packages = ["src/hub/transport/http", "src/bridge"] + [
        p for p in packages if p not in {"src/hub/transport/http", "src/bridge"}]
    packages += sorted({str(p.parent.relative_to(root)) for p in (root/"tests").glob("*/main.odin")
                        if "@(test)" in p.read_text()})
    for i, package in enumerate(packages):
        run(package, ["odin", "test", package, "-collection:odin_test=src",
                      "-define:ODIN_TEST_THREADS=1", "-out:" + str(out/f"package-{i}")],
            timeout=900, expects_tests=True)
    # These files are programs with main(), not Odin @(test) packages.
    for i, path in enumerate(sorted((root/"tests").glob("*_test.odin"))):
        if re.search(r"^main\s*::\s*proc", path.read_text(), re.M):
            relative = str(path.relative_to(root))
            run(relative, ["odin", "run", relative, "-file", "-collection:odin_test=src",
                           "-out:" + str(out/f"program-{i}")], timeout=180)
elif args.group == "ui":
    run("npm-test", ["npm", "test"], timeout=900, expects_tests=True)
    run("npm-build", ["npm", "run", "build"], timeout=900)
else:
    run("provider-extension-distribution", ["python3", "tests/provider_extension_distribution_test.py"], timeout=300)
    run("local-runtime", ["node", "--test", "scripts/local-runtime/helpers.test.mjs"])
    run("http-boundary", ["bash", "scripts/check-http-boundary.sh"])

print(json.dumps(dict(group=args.group, passed=sum(r["passed"] for r in rows),
                      failed=sum(not r["passed"] for r in rows), results=str(out/"results.json"))), flush=True)
raise SystemExit(0 if all(r["passed"] for r in rows) else 1)
