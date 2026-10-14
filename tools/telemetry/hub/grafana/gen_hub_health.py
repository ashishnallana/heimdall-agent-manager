#!/usr/bin/env python3
"""Generate tools/telemetry/hub/grafana/dashboards/hub-health.json.

Hand-maintaining Grafana JSON is error-prone; this script is the source of
truth for the Hub Health dashboard. Re-run it and commit the JSON when panels
change:  python3 tools/telemetry/hub/grafana/gen_hub_health.py
"""
import json
import os

DS = {"type": "prometheus", "uid": "heimdall-prometheus"}
JOB = 'job="heimdall-hub"'

_id = [0]


def nid():
    _id[0] += 1
    return _id[0]


def target(expr, legend="", instant=False):
    t = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": chr(ord("A") + target.n)}
    if instant:
        t["instant"] = True
    target.n += 1
    return t


target.n = 0


def panel(title, exprs, x, y, w=12, h=8, unit="short", kind="timeseries", desc="", extra_fc=None, options=None):
    target.n = 0
    targets = [target(*e) if isinstance(e, tuple) else target(e) for e in exprs]
    fc = {"defaults": {"unit": unit}, "overrides": []}
    if extra_fc:
        fc["defaults"].update(extra_fc)
    p = {
        "id": nid(),
        "type": kind,
        "title": title,
        "description": desc,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": fc,
        "targets": targets,
        "options": options or {},
    }
    if kind == "timeseries":
        p["options"] = {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}
    return p


def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


stat_opts = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "value", "graphMode": "none", "textMode": "auto"}

panels = [
    row("Overview", 0),
    panel("Hub scrape up", [(f'up{{{JOB}}}', "up", True)], 0, 1, w=4, h=4, kind="stat",
          options=stat_opts, extra_fc={"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}, "mappings": [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]}),
    panel("Build", [(f'heimdall_hub_build_info{{{JOB}}}', "{{version}} @ {{commit}}", True)], 4, 1, w=8, h=4, kind="stat",
          options={**stat_opts, "textMode": "name"}, extra_fc={"color": {"mode": "fixed", "fixedColor": "text"}}),
    panel("In flight", [(f'heimdall_http_in_flight{{{JOB}}}', "in flight", True)], 12, 1, w=4, h=4, kind="stat", options=stat_opts),
    panel("Threads", [(f'process_threads{{{JOB}}}', "threads", True)], 16, 1, w=4, h=4, kind="stat", options=stat_opts,
          extra_fc={"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1000}, {"color": "red", "value": 2000}]}}),
    panel("FD usage", [(f'process_open_fds{{{JOB}}} / process_max_fds{{{JOB}}}', "fds", True)], 20, 1, w=4, h=4, kind="stat", unit="percentunit", options=stat_opts,
          extra_fc={"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.6}, {"color": "red", "value": 0.8}]}}),

    row("HTTP", 5),
    panel("Requests/s by status class", [('sum by (status_class) (rate(heimdall_http_requests_total[5m]))', "{{status_class}}")], 0, 6, unit="reqps",
          desc="Router dispatches only; WebSocket upgrades and the preview relay are excluded."),
    panel("5xx ratio", [('sum(rate(heimdall_http_requests_total{status_class="5xx"}[5m])) / sum(rate(heimdall_http_requests_total[5m]))', "5xx ratio")], 12, 6, unit="percentunit",
          extra_fc={"min": 0, "max": 1}),
    panel("Latency p50 / p95 / p99", [
        ('histogram_quantile(0.50, sum by (le) (rate(heimdall_http_request_duration_seconds_bucket[5m])))', "p50"),
        ('histogram_quantile(0.95, sum by (le) (rate(heimdall_http_request_duration_seconds_bucket[5m])))', "p95"),
        ('histogram_quantile(0.99, sum by (le) (rate(heimdall_http_request_duration_seconds_bucket[5m])))', "p99"),
    ], 0, 14, unit="s"),
    panel("p95 latency by route (top 10)", [('topk(10, histogram_quantile(0.95, sum by (route, le) (rate(heimdall_http_request_duration_seconds_bucket[5m]))))', "{{route}}")], 12, 14, unit="s"),
    panel("Requests/s by route (top 10)", [('topk(10, sum by (route) (rate(heimdall_http_requests_total[5m])))', "{{route}}")], 0, 22, unit="reqps"),
    panel("Errors by route (4xx / 5xx)", [
        ('topk(10, sum by (route) (rate(heimdall_http_requests_total{status_class="5xx"}[5m])))', "5xx {{route}}"),
        ('topk(10, sum by (route) (rate(heimdall_http_requests_total{status_class="4xx"}[5m])))', "4xx {{route}}"),
    ], 12, 22, unit="reqps"),
    panel("accept() errors (10m increase)", [(f'increase(heimdall_http_accept_errors_total{{{JOB}}}[10m])', "accept errors")], 0, 30, unit="short", h=6),
    panel("In flight", [(f'heimdall_http_in_flight{{{JOB}}}', "in flight")], 12, 30, unit="short", h=6),

    row("Process", 36),
    panel("Memory", [
        (f'process_resident_memory_bytes{{{JOB}}}', "RSS"),
        (f'process_virtual_memory_bytes{{{JOB}}}', "VSZ"),
    ], 0, 37, unit="bytes"),
    panel("CPU (cores)", [(f'rate(process_cpu_seconds_total{{{JOB}}}[5m])', "cpu")], 12, 37, unit="short"),
    panel("Threads", [(f'process_threads{{{JOB}}}', "threads")], 0, 45, unit="short",
          desc="One OS thread per TCP connection: ≈ in-flight HTTP + live WebSockets."),
    panel("File descriptors", [
        (f'process_open_fds{{{JOB}}}', "open"),
        (f'process_max_fds{{{JOB}}}', "max"),
    ], 12, 45, unit="short"),
    panel("Uptime", [(f'time() - process_start_time_seconds{{{JOB}}}', "uptime")], 0, 53, unit="s", h=6),
    panel("Metrics self: series / scrape time", [
        (f'heimdall_metrics_series{{{JOB}}}', "series"),
        (f'heimdall_metrics_scrape_duration_seconds{{{JOB}}} * 1000', "scrape ms"),
    ], 12, 53, unit="short", h=6),

    row("Host (node_exporter)", 59),
    panel("Host CPU busy", [('1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))', "busy")], 0, 60, unit="percentunit", extra_fc={"min": 0, "max": 1}),
    panel("Host memory available", [('node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "available")], 12, 60, unit="percentunit", extra_fc={"min": 0, "max": 1}),
    panel("Root filesystem free", [('node_filesystem_avail_bytes{mountpoint="/"}', "free")], 0, 68, unit="bytes", h=6),
    panel("Public probe: success / cert days left", [
        ('probe_success{job="blackbox"}', "probe_success"),
        ('(probe_ssl_earliest_cert_expiry{job="blackbox"} - time()) / 86400', "cert days left"),
    ], 12, 68, unit="short", h=6),
]

dashboard = {
    "uid": "heimdall-hub-health",
    "title": "Heimdall / Hub Health",
    "tags": ["heimdall"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "editable": False,
    "graphTooltip": 1,
    "time": {"from": "now-6h", "to": "now"},
    "refresh": "30s",
    "templating": {"list": []},
    "annotations": {"list": []},
    "panels": panels,
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards", "hub-health.json")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    json.dump(dashboard, f, indent=2, sort_keys=True)
    f.write("\n")
print("wrote", out)
