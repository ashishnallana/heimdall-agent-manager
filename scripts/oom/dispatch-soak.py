#!/usr/bin/env python3
"""Identical hub->bridge command soak against several bridges on one isolated hub.

Every op goes hub -> bridge over the command channel and is executed on a bridge
dispatch worker (fs_list_dir / fs_read_file). Ops are interleaved across bridges so
each bridge sees the same mix at the same rate. Any failed op aborts the run (exit 1).
Every --sample seconds one CSV row per bridge: elapsed_s, label, pid, rss_kib,
threads, ops_ok.

usage: dispatch-soak.py --proxy http://127.0.0.1:18480 --origin http://127.0.0.1:15473 \
         --bridge A=brg_x:PID --bridge B=brg_y:PID --dir DIR --small FILE --big FILE \
         --minutes 20 --rate 4 --big-every 60 --out soak.csv
"""
import argparse, json, sys, time, urllib.parse, urllib.request

def proc(pid):
    rss = thr = -1
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"): rss = int(line.split()[1])
            elif line.startswith("Threads:"): thr = int(line.split()[1])
    return rss, thr

def call(a, bridge, route, path):
    url = f"{a.proxy}/api/v1/bridges/{bridge}/{route}?path={urllib.parse.quote(path)}"
    req = urllib.request.Request(url, headers={"Origin": a.origin})
    with urllib.request.urlopen(req, timeout=60) as r:
        body = json.load(r)
    d = body.get("data") or {}
    if not d.get("ok"):
        raise RuntimeError(f"{route} {path} -> {json.dumps(body)[:300]}")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--proxy", required=True); p.add_argument("--origin", required=True)
    p.add_argument("--bridge", action="append", required=True, help="LABEL=bridge_id:pid")
    p.add_argument("--dir", required=True); p.add_argument("--small", required=True)
    p.add_argument("--big", required=True)
    p.add_argument("--minutes", type=float, default=20); p.add_argument("--rate", type=float, default=4)
    p.add_argument("--big-every", type=int, default=60, help="every Nth cycle also reads --big")
    p.add_argument("--sample", type=float, default=30); p.add_argument("--out", required=True)
    a = p.parse_args()
    bridges = []
    for spec in a.bridge:
        label, rest = spec.split("=", 1); bid, pid = rest.split(":")
        bridges.append((label, bid, int(pid)))
    ops = [("fs", a.dir), ("fs/file", a.small)]
    ok = {b[0]: 0 for b in bridges}
    out = open(a.out, "w", buffering=1)
    out.write("elapsed_s,label,pid,rss_kib,threads,ops_ok\n")
    t0 = time.time(); next_sample = t0; cycle = 0
    end = t0 + a.minutes * 60
    while True:
        now = time.time()
        if now >= next_sample:
            for label, _, pid in bridges:
                rss, thr = proc(pid)
                out.write(f"{now - t0:.0f},{label},{pid},{rss},{thr},{ok[label]}\n")
            next_sample += a.sample
        if now >= end: break
        cyc_ops = list(ops) + ([("fs/file", a.big)] if a.big_every and cycle % a.big_every == 0 else [])
        for route, path in cyc_ops:
            for label, bid, _ in bridges:
                try:
                    call(a, bid, route, path); ok[label] += 1
                except Exception as e:
                    print(f"FAIL {label} {route} {path}: {e}", file=sys.stderr); sys.exit(1)
        cycle += 1
        time.sleep(max(0.0, (1.0 / a.rate) - (time.time() - now)))
    print(json.dumps({"cycles": cycle, "ops_ok": ok, "seconds": round(time.time() - t0)}))

if __name__ == "__main__":
    main()
