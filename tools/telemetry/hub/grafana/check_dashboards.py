#!/usr/bin/env python3
"""Static checks for the Grafana dashboards (run by verify-db-dashboard.sh).

  check_dashboards.py <repo-root> <rules-out.yml>

1. Every dashboards/*.json parses and has the fields Grafana provisioning
   needs; dashboard UIDs are unique across files and panel ids within a file.
2. Every Prometheus target uses the provisioned datasource UID.
3. Hub DB dashboard: every metric is registered in src/ (non-test code), every
   new DB family is documented in docs/reference/db-telemetry.md, every label
   matcher belongs to its own metric's family, its values and `le` bounds
   exist in the source label/bucket tables, every `by (...)` label belongs to
   one of the expression's families, every selector is scoped to
   the selected job + instance, and no query fabricates zeros (`or vector(0)`).
4. Writes every Prometheus expression, with the Grafana variables replaced by
   sample values, as a recording-rule file for `promtool check rules` (PromQL
   syntax only; no live Prometheus is queried).
"""
import glob
import json
import os
import re
import subprocess
import sys

root, rules_out = sys.argv[1], sys.argv[2]
graf = os.path.join(root, "tools/telemetry/hub/grafana")
errors = []


def err(msg):
    errors.append(msg)


def load_yaml_uid(path, kind):
    # The datasource file is tiny; avoid a yaml dependency.
    text = open(path).read()
    m = re.search(r"uid:\s*(\S+)", text)
    if not m:
        sys.exit(f"no uid in {path}")
    return m.group(1)


PROM_UID = load_yaml_uid(os.path.join(graf, "provisioning/datasources/prometheus.yml"), "prometheus")

# --- 1/2: structure, UIDs, panel ids, datasources -------------------------
dashboards = {}
for path in sorted(glob.glob(os.path.join(graf, "dashboards/*.json"))):
    name = os.path.basename(path)
    try:
        d = json.load(open(path))
    except ValueError as e:
        err(f"{name}: invalid JSON: {e}")
        continue
    dashboards[name] = d
    for key in ("uid", "title", "schemaVersion", "panels"):
        if key not in d:
            err(f"{name}: missing {key}")
    ids = []
    for p in d.get("panels", []):
        for key in ("id", "type", "title", "gridPos"):
            if key not in p:
                err(f"{name}: panel {p.get('title')!r} missing {key}")
        ids.append(p.get("id"))
        g = p.get("gridPos", {})
        if g.get("x", 0) + g.get("w", 0) > 24:
            err(f"{name}: panel {p.get('id')} wider than the 24-column grid")
        for t in p.get("targets", []):
            ds = t.get("datasource") or p.get("datasource") or {}
            if ds.get("type") == "prometheus" and ds.get("uid") != PROM_UID:
                err(f"{name}: panel {p.get('id')} uses datasource uid {ds.get('uid')!r}, provisioned is {PROM_UID!r}")
    dups = {i for i in ids if ids.count(i) > 1}
    if dups:
        err(f"{name}: duplicate panel ids {sorted(dups)}")
uids = [d.get("uid") for d in dashboards.values()]
for u in {u for u in uids if uids.count(u) > 1}:
    err(f"duplicate dashboard uid {u}")

# --- 3: Hub DB metric / label validation against the implementation -------
src_files = [f for f in subprocess.check_output(["git", "-C", root, "ls-files", "src/*.odin"], text=True).split()
             if not f.endswith("_test.odin")]
src = "\n".join(open(os.path.join(root, f)).read() for f in src_files)
reference = open(os.path.join(root, "docs/reference/db-telemetry.md")).read()

# Registered families and their label names: new_counter/new_gauge/new_histogram_seconds(reg, "name", "help", {"a", "b"}, ...).
families = {}
for m in re.finditer(r'new_(?:counter|gauge|histogram_seconds)\(\s*reg,\s*"(heimdall_\w+)",\s*"(?:[^"\\]|\\.)*"\s*(?:,\s*\{([^}]*)\})?', src):
    families[m.group(1)] = set(re.findall(r'"(\w+)"', m.group(2) or ""))
# Scrape-collector families (expo_header + expo_sample_i64 with a names slice).
COLLECTED = {
    "heimdall_db_lock_waiters_max": {"lock"},
    "heimdall_sqlite_cache_events_total": {"conn", "kind"},
    "heimdall_db_uow_oldest_hold_seconds": set(),
    "heimdall_sqlite_db_bytes": set(),
    "heimdall_sqlite_wal_bytes": set(),
}
for fam, labels in COLLECTED.items():
    if f'expo_header(e, "{fam}"' not in src:
        err(f"collector family {fam} not found in src (update COLLECTED)")
    families[fam] = labels



def enum_table(name):
    """Quoted values of an Odin `NAME := [Enum]string { .X = "x", ... }` label table."""
    m = re.search(name + r"\s*:=\s*\[\w+\]string\s*\{([^}]*)\}", src)
    if not m:
        err(f"label table {name} not found in src/")
        return set()
    return set(re.findall(r'"(\w+)"', m.group(1)))


# Allowed values per label, read from the implementation's label tables.
cache_kinds = set(re.findall(r'\{SQLITE_DBSTATUS_CACHE_\w+,\s*"(\w+)"\}', src))
rw = re.search(r'rw_labels\s*:=\s*\[2\]string\{([^}]*)\}', src)
LABEL_VALUES = {
    "lock": enum_table("LOCK_LABELS"),
    "conn": enum_table("CONN_LABELS"),
    "op": enum_table("OP_LABELS"),
    "code": enum_table("ERR_LABELS"),
    "component": enum_table("COMPONENT_LABELS"),
    "scope": enum_table("SCOPE_LABELS"),
    "outcome": enum_table("TX_OUTCOME_LABELS"),
    "reason": enum_table("SLOW_REASON_LABELS"),
    "rw": set(re.findall(r'"(\w+)"', rw.group(1))) if rw else set(),
}
# `kind` is the tx kind on heimdall_db_tx_duration_seconds and the cache event kind on cache_events.
TX_KINDS = enum_table("TX_KIND_LABELS")
CACHE_KINDS = cache_kinds
if not cache_kinds or not LABEL_VALUES["rw"]:
    err("cache kinds / rw labels not found in src/")


def value_ok(fam, label, value):
    """A literal value must be in the label's table; a regex alternative must match one entry."""
    allowed = LABEL_VALUES.get(label)
    if label == "kind":
        allowed = CACHE_KINDS if fam == "heimdall_sqlite_cache_events_total" else TX_KINDS
    if allowed is None:
        return f'"{value}"' in src
    return any(re.fullmatch(value, v) for v in allowed)


def float_table(name):
    m = re.search(name + r"\s*:=\s*\[\?\]f64\{([^}]*)\}", src)
    if not m:
        err(f"bucket table {name} not found in src/")
        return set()
    return {float(x) for x in m.group(1).split(",") if x.strip()}


BUCKETS = {
    "heimdall_db_lock_wait_seconds": float_table("LOCK_WAIT_BUCKETS"),
    "heimdall_db_lock_hold_seconds": float_table("HOLD_BUCKETS"),
    "heimdall_db_tx_duration_seconds": float_table("HOLD_BUCKETS"),
    "heimdall_sqlite_exec_seconds": float_table("EXEC_BUCKETS"),
    # Either layout may be live (off vs basic); only bounds present in both are always safe.
    "heimdall_http_request_duration_seconds": float_table("HTTP_DURATION_BUCKETS") & float_table("HTTP_DURATION_BUCKETS_FINE"),
}


HIST_SUFFIX = re.compile(r"_(bucket|sum|count)$")
SCOPE = 'job="$job",instance="$instance"'
SKIP_LABELS = {"le", "job", "instance"}


def family_of(metric):
    if metric in families:
        return metric
    base = HIST_SUFFIX.sub("", metric)
    return base if base in families else None


hub_db = dashboards.get("hub-db.json")
if hub_db is None:
    err("hub-db.json missing")
else:
    seen = set()
    for p in hub_db.get("panels", []):
        for t in p.get("targets", []):
            expr = t["expr"]
            if "vector(0)" in expr:
                err(f"hub-db panel {p['id']}: fabricates zeros with vector(0)")
            if re.search(r"\bheimdall_\w+\b(?!\s*\{)", expr.replace('"heimdall', "")):
                err(f"hub-db panel {p['id']}: metric without a job/instance selector: {expr}")
            fams = set()
            # Every selector, checked against its own metric's family.
            for metric, body in re.findall(r"\b(heimdall_\w+)\s*\{([^}]*)\}", expr):
                fam = family_of(metric)
                if fam is None:
                    err(f"hub-db panel {p['id']}: {metric} is not registered in src/")
                    continue
                fams.add(fam)
                seen.add(fam)
                if not body.startswith(SCOPE):
                    err(f"hub-db panel {p['id']}: selector not scoped to job+instance: {metric}{{{body}}}")
                for label, op, value in re.findall(r'(\w+)\s*(=~|!~|!=|=)\s*"([^"]*)"', body):
                    if label in ("job", "instance"):
                        continue
                    if label == "le":
                        bounds = BUCKETS.get(fam)
                        if not metric.endswith("_bucket") or bounds is None:
                            err(f"hub-db panel {p['id']}: le on non-bucket series {metric}")
                        elif not any(abs(float(value) - b) < 1e-12 for b in bounds):
                            err(f"hub-db panel {p['id']}: le={value!r} is not a bound of {fam} {sorted(bounds)}")
                        continue
                    if label not in families[fam]:
                        err(f"hub-db panel {p['id']}: label {label!r} is not a label of {fam}")
                        continue
                    if "$" in value:
                        continue  # Grafana variable; its options are checked below
                    alts = value.split("|") if "~" in op else [re.escape(value)]
                    for alt in alts:
                        if not value_ok(fam, label, alt):
                            err(f"hub-db panel {p['id']}: {label}{op}{value!r} on {fam} matches no value emitted by src/")
            allowed = set().union(*(families[f] for f in fams)) if fams else set()
            # label_replace introduces `conn` from `lock`.
            if "label_replace(" in expr:
                allowed |= {"conn"}
            for clause in re.findall(r"\bby\s*\(([^)]*)\)", expr):
                for label in {x.strip() for x in clause.split(",") if x.strip()} - SKIP_LABELS - allowed:
                    err(f"hub-db panel {p['id']}: by ({label}) is not a label of {sorted(fams)}")
    # Custom variable options must be real label values too.
    for v in hub_db.get("templating", {}).get("list", []):
        if v.get("type") == "custom" and v["name"] in LABEL_VALUES:
            for opt in v["query"].split(","):
                if opt not in LABEL_VALUES[v["name"]]:
                    err(f"hub-db variable {v['name']}: option {opt!r} is not emitted by src/")
    new_db = {f for f in seen if f.startswith(("heimdall_db_", "heimdall_sqlite_", "heimdall_http_request_db"))
              and f not in ("heimdall_sqlite_busy_total", "heimdall_sqlite_db_bytes", "heimdall_sqlite_wal_bytes")}
    for fam in sorted(new_db):
        stem = fam.replace("heimdall_sqlite_site_", "").replace("heimdall_sqlite_", "")
        if fam not in reference and f"_{stem}" not in reference:
            err(f"{fam} is used by hub-db but not documented in docs/reference/db-telemetry.md")
    # Every phase-1 family the reference lists should have a panel.
    for fam in sorted(f for f in families if f.startswith(("heimdall_db_", "heimdall_http_request_db")) or
                      f in ("heimdall_sqlite_exec_seconds", "heimdall_sqlite_statements_total", "heimdall_sqlite_vm_steps_total",
                            "heimdall_sqlite_fullscan_steps_total", "heimdall_sqlite_sort_total", "heimdall_sqlite_errors_total",
                            "heimdall_sqlite_cache_events_total", "heimdall_sqlite_library_info", "heimdall_sqlite_site_exec_seconds_total",
                            "heimdall_sqlite_site_vm_steps_total", "heimdall_sqlite_site_fullscan_steps_total")):
        if fam not in seen and fam != "heimdall_db_lock_held":
            err(f"phase-1 family {fam} has no hub-db panel")
    print(f"hub-db: {len(seen)} families validated against src/")

# --- 4: PromQL for promtool -------------------------------------------------
SAMPLES = {"__range": "1h", "__rate_interval": "5m", "job": "heimdall-hub", "instance": "127.0.0.1:9464",
           "conn": "main", "owner": ".*", "bridge": ".*", "bridge_id": ".*", "code": ".*", "level": ".*"}
var_re = re.compile(r"\$(" + "|".join(sorted(SAMPLES, key=len, reverse=True)) + r")\b")
lines = ["groups:", "  - name: dashboard_syntax", "    rules:"]
n = 0
for name, d in dashboards.items():
    for p in d.get("panels", []):
        for t in p.get("targets", []):
            ds = t.get("datasource") or p.get("datasource") or {}
            if ds.get("type") != "prometheus":
                continue
            expr = var_re.sub(lambda m: SAMPLES[m.group(1)], t["expr"])
            if re.search(r"\$[A-Za-z_]", expr):
                err(f"{name} panel {p['id']}: unknown Grafana variable in {t['expr']}")
            n += 1
            lines.append(f"      - record: dashboard:{os.path.splitext(name)[0].replace('-', '_')}:p{p['id']}_{t['refId']}")
            lines.append("        expr: " + json.dumps(expr))
with open(rules_out, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"wrote {n} expressions to {rules_out}")

if errors:
    print("\n".join("FAIL: " + e for e in errors))
    sys.exit(1)
print("dashboard static checks: PASS")
