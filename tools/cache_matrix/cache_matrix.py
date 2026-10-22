#!/usr/bin/env python3
"""cache_size / mmap_size matrix for the Hub's hottest read SQL (REQ-CACHE).

Drives the sqlite3 CLI (same 3.53.3 library line as the Hub) against a COPY of a
prod-shaped fixture DB (tests/sqlite_index_eval.odin `prod` scale). One CLI
process = one connection, so its max RSS is a per-connection figure.

  warm: OS page cache holds the file; one connection runs PASSES passes of the
        workload; pass 1 = cold connection cache, passes 2.. = warm steady state.
  cold: a fresh copy of the file, fsync'd, then posix_fadvise(DONTNEED) evicts it
        from the OS page cache (no root); fincore confirms 0 resident pages first.

Usage: cache_matrix.py <fixture.db> <scratch-dir>
Read-only workload; the fixture itself is never opened, only copies.
"""
import os, re, shutil, subprocess, sys

PASSES = 5
REPEAT = 10  # calls per statement per pass, as the task-1 replay does
TERMINAL = "('exited','failed','killed')"
WORKLOAD = [
    ("conversations(limit 200)", open(os.path.join(os.path.dirname(__file__), "conversations.sql")).read().strip()),
    ("live_bridge_ids", f"SELECT DISTINCT bridge_id FROM shell_sessions WHERE bridge_id != '' AND status NOT IN {TERMINAL} ORDER BY bridge_id ASC LIMIT 500;"),
    ("live_by_kind(server)", f"SELECT session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id, kind, label, cmd, cwd, status, exit_code, pid, server_port, started_at, finished_at, created_at, last_activity_at, background, conversation_id, kill_requested_at, run_seq FROM shell_sessions WHERE kind = 'server' AND status NOT IN {TERMINAL} ORDER BY started_at ASC, session_id ASC LIMIT 100;"),
    ("retention scan (SELECT form)", f"SELECT owner_user_id FROM shell_sessions WHERE status IN {TERMINAL} AND COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at) < '2000-01-01T00:00:00Z';"),
    ("dependencies_by_chain", "SELECT task_id, depends_on_task_id, chain_id, owner_user_id, created_at FROM task_dependencies WHERE chain_id = 'chain_0' AND owner_user_id = 'index-owner' ORDER BY created_at ASC;"),
]
CONFIGS = [  # (label, cache_size pragma value or None, mmap bytes or None)
    ("default (-2000 = 2 MiB, mmap 0)", None, None),
    ("cache_size=-8000 (8 MiB)", -8000, None),
    ("cache_size=-16000 (16 MiB)", -16000, None),
    ("mmap_size=64 MiB", None, 64 << 20),
    ("cache -8000 + mmap 64 MiB", -8000, 64 << 20),
]

def script(cache, mmap, passes):
    lines = [".stats on", ".timer on"]
    if cache is not None: lines.append(f"PRAGMA cache_size={cache};")
    if mmap is not None: lines.append(f"PRAGMA mmap_size={mmap};")
    for p in range(passes):
        lines.append(f".print PASS {p+1}")
        for _, sql in WORKLOAD:
            lines += [sql] * REPEAT
    return "\n".join(lines) + "\n"

def run(db, cache, mmap, passes):
    p = subprocess.run(["/usr/bin/time", "-f", "MAXRSS_KB %M", "sqlite3", "-readonly", db],
                       input=script(cache, mmap, passes), capture_output=True, text=True, check=True)
    out = p.stdout + p.stderr
    per = {}  # pass -> [hits, misses, real seconds]
    cur = 0
    for line in out.splitlines():
        if line.startswith("PASS "): cur = int(line.split()[1]); per[cur] = [0, 0, 0.0]; continue
        if cur == 0: continue
        m = re.match(r"\s*Page cache hits:\s+(\d+)", line)
        if m: per[cur][0] += int(m.group(1))
        m = re.match(r"\s*Page cache misses:\s+(\d+)", line)
        if m: per[cur][1] += int(m.group(1))
        m = re.match(r"Run Time: real ([0-9.]+)", line)
        if m: per[cur][2] += float(m.group(1))
    rss = int(re.search(r"MAXRSS_KB (\d+)", out).group(1))
    return per, rss

def fresh_cold_copy(src, dst):
    for suf in ("", "-wal", "-shm"):
        if os.path.exists(dst + suf): os.remove(dst + suf)
    shutil.copyfile(src, dst)
    fd = os.open(dst, os.O_RDONLY)
    os.fsync(fd); os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED); os.close(fd)
    res = subprocess.run(["fincore", "-nb", "-o", "RES", dst], capture_output=True, text=True).stdout.strip()
    return res

def ratio(h, m): return 100.0 * m / (h + m) if h + m else 0.0

def main():
    fixture, scratch = sys.argv[1], sys.argv[2]
    os.makedirs(scratch, exist_ok=True)
    warm_db = os.path.join(scratch, "warm.db")
    shutil.copyfile(fixture, warm_db)
    pages = subprocess.run(["sqlite3", "-readonly", warm_db, "PRAGMA page_count;"], capture_output=True, text=True).stdout.strip()
    print(f"fixture {fixture}: {os.path.getsize(fixture)} bytes, {pages} pages of 4096; workload = {len(WORKLOAD)} statements x {REPEAT} per pass")
    _, idle_rss = run(warm_db, None, None, 0)
    print(f"idle CLI connection max RSS (open, no workload, default pragmas): {idle_rss} KiB\n")
    print("| Config | Mode | Pass-1 hits | Pass-1 misses | Pass-1 miss % | Pass-1 ms | Warm (passes 2-5) misses | Warm miss % | Warm ms/pass | Max RSS KiB | RSS over idle KiB |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for label, cache, mmap in CONFIGS:
        for mode in ("warm", "cold"):
            if mode == "cold":
                db = os.path.join(scratch, "cold.db")
                res = fresh_cold_copy(fixture, db)
                assert res == "0", f"cold copy still has {res} resident bytes"
            else:
                db = warm_db
                run(db, None, None, 1)  # make sure the OS page cache holds the file
            per, rss = run(db, cache, mmap, PASSES)
            h1, m1, t1 = per[1]
            wh = sum(per[p][0] for p in range(2, PASSES + 1)); wm = sum(per[p][1] for p in range(2, PASSES + 1))
            wt = sum(per[p][2] for p in range(2, PASSES + 1)) / (PASSES - 1)
            print(f"| {label} | {mode} | {h1} | {m1} | {ratio(h1, m1):.2f} | {t1*1000:.1f} | {wm} | {ratio(wh, wm):.2f} | {wt*1000:.1f} | {rss} | {rss - idle_rss} |")

if __name__ == "__main__":
    main()
