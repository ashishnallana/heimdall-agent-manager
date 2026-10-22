#!/usr/bin/env python3
"""Generate the Heimdall Grafana dashboards (hub-health, fleet, streams, bridge-events, hub-db).

Hand-maintaining Grafana JSON is error-prone; this script is the source of
truth for every dashboard above (task-system-v2.json is still hand-maintained).
Re-run it and commit the JSON when panels change:
  python3 tools/telemetry/hub/grafana/gen_dashboards.py
verify-db-dashboard.sh fails when the committed JSON differs from the output.
"""
import json
import os

DS = {"type": "prometheus", "uid": "heimdall-prometheus"}
# Optional VictoriaLogs datasource (bridge_logs plan v2 section 5); panels that
# use it show "datasource not found" until services.heimdall-telemetry.logs is on.
LOGS_DS = {"type": "victoriametrics-logs-datasource", "uid": "heimdall-victorialogs"}
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


def panel(title, exprs, x, y, w=12, h=8, unit="short", kind="timeseries", desc="", extra_fc=None, options=None, ds=None, no_value=None):
    target.n = 0
    targets = [target(*e) if isinstance(e, tuple) else target(e) for e in exprs]
    if ds is not None:
        for t in targets:
            t["datasource"] = ds
    fc = {"defaults": {"unit": unit}, "overrides": []}
    if no_value is not None:
        fc["defaults"]["noValue"] = no_value
    if extra_fc:
        fc["defaults"].update(extra_fc)
    p = {
        "id": nid(),
        "type": kind,
        "title": title,
        "description": desc,
        "datasource": ds or DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": fc,
        "targets": targets,
        "options": options or {},
    }
    if kind == "timeseries":
        p["options"] = {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}
    return p


def logs_panel(title, query, x, y, w=24, h=12, desc=""):
    """A VictoriaLogs logs panel (LogsQL). Stream labels are {job, level}; bridge_id/code are
    structured-metadata fields, so they are filtered with `field:~"regex"`, never selected
    as a stream."""
    return {
        "id": nid(),
        "type": "logs",
        "title": title,
        "description": desc,
        "datasource": LOGS_DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True, "dedupStrategy": "none"},
        "targets": [{"datasource": LOGS_DS, "refId": "A", "expr": query, "queryType": "instant"}],
    }


def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


def text_panel(title, content, x, y, w=24, h=8):
    """A static Markdown panel for caveats and reading guides."""
    return {
        "id": nid(),
        "type": "text",
        "title": title,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "options": {"mode": "markdown", "content": content},
    }


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
    ], 0, 14, unit="s",
          desc="Bucket-interpolated. DB telemetry (basic, the default) adds a 2.5 ms bound to this histogram: do not read a quantile across that deploy. DB share of request time: Heimdall / Hub DB."),
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
    # Every generated dashboard links to the others (Hub Health <-> Hub DB included).
    "links": [{"title": "Heimdall dashboards", "type": "dashboards", "tags": ["heimdall"], "asDropdown": True, "keepTime": True, "includeVars": False, "targetBlank": False}],
    "panels": panels,
}


def write(name, dash):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards", name)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(dash, f, indent=2, sort_keys=True)
        f.write("\n")
    print("wrote", out)


write("hub-health.json", dashboard)

# ---------------------------------------------------------------------------
# Fleet: per-bridge view with an `owner` variable resolved through bridge_info.
OWNER_JOIN = ' * on(bridge_id) group_left(owner) heimdall_bridge_info{owner=~"$owner"}'
BRIDGE_SEL = 'bridge_id=~"$bridge"'

fleet_panels = [
    row("Fleet", 0),
    panel("Bridges online", [('heimdall_bridges_online', "online", True)], 0, 1, w=4, h=4, kind="stat", options=stat_opts),
    panel("Bridges by status", [('heimdall_bridges', "{{status}}", True)], 4, 1, w=8, h=4, kind="stat", options={**stat_opts, "textMode": "value_and_name"}),
    panel("Users / active 7d", [('heimdall_users', "users", True), ('heimdall_users_active{window="7d"}', "active 7d", True)], 12, 1, w=6, h=4, kind="stat", options={**stat_opts, "textMode": "value_and_name"}),
    panel("Instances active", [('sum(heimdall_agent_instances)', "instances", True)], 18, 1, w=6, h=4, kind="stat", options=stat_opts),
    panel("Connects/s by result", [('sum by (result) (rate(heimdall_bridge_ws_connects_total[5m]))', "{{result}}")], 0, 5, unit="ops"),
    panel("Disconnects/s by reason", [('sum by (reason) (rate(heimdall_bridge_ws_disconnects_total[5m]))', "{{reason}}")], 12, 5, unit="ops"),
    panel("Reconnects per bridge (10m, top 10)", [('topk(10, sum by (bridge_id) (increase(heimdall_bridge_ws_connects_total[10m])))', "{{bridge_id}}")], 0, 13, unit="short"),
    panel("Heartbeat age (s, top 10)", [('topk(10, time() - heimdall_bridge_last_heartbeat_timestamp_seconds{' + BRIDGE_SEL + '}' + OWNER_JOIN + ')', "{{bridge_id}} {{owner}}")], 12, 13, unit="s",
          extra_fc={"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 180}]}}),
    panel("Session duration p50/p95", [
        ('histogram_quantile(0.5, sum by (le) (rate(heimdall_bridge_session_duration_seconds_bucket[1h])))', "p50"),
        ('histogram_quantile(0.95, sum by (le) (rate(heimdall_bridge_session_duration_seconds_bucket[1h])))', "p95"),
    ], 0, 21, unit="s"),
    panel("Frames/s by type (rx)", [('sum by (type) (rate(heimdall_bridge_ws_frames_total{direction="rx"}[5m]))', "{{type}}")], 12, 21, unit="ops"),
    panel("Bytes/s per bridge (top 10)", [('topk(10, sum by (bridge_id, direction) (rate(heimdall_bridge_ws_bytes_total{' + BRIDGE_SEL + '}[5m])))', "{{bridge_id}} {{direction}}")], 0, 29, unit="Bps"),
    panel("Rejected frames / limit rejections", [
        ('sum by (reason) (rate(heimdall_bridge_frames_rejected_total[5m]))', "rejected {{reason}}"),
        ('sum by (limit) (rate(heimdall_limit_rejections_total[5m]))', "limit {{limit}}"),
    ], 12, 29, unit="ops"),
    panel("Command RTT p95 by command", [('histogram_quantile(0.95, sum by (command, le) (rate(heimdall_bridge_command_duration_seconds_bucket[5m])))', "{{command}}")], 0, 37, unit="s"),
    panel("Command errors/s", [('sum by (command, code) (rate(heimdall_bridge_command_errors_total[5m]))', "{{command}} {{code}}")], 12, 37, unit="ops"),

    row("Agent instances", 45),
    panel("Instances by status", [('sum by (status) (heimdall_agent_instances)', "{{status}}")], 0, 46, unit="short"),
    panel("Starts / exits per minute", [
        ('sum by (status) (increase(heimdall_agent_instance_starts_total[5m])) / 5', "start {{status}}"),
        ('sum by (status) (increase(heimdall_agent_instance_exits_total[5m])) / 5', "exit {{status}}"),
    ], 12, 46, unit="short"),
    panel("Reconciled gone (10m)", [('increase(heimdall_agent_instances_reconciled_gone_total[10m])', "gone")], 0, 54, unit="short", h=6),
    panel("Bridge updates", [('sum by (result) (increase(heimdall_bridge_updates_total[1h]))', "{{result}}")], 12, 54, unit="short", h=6),

    row("Bridge host resources (from heartbeat stats)", 60),
    panel("Bridge process RSS", [('heimdall_bridge_process_resident_bytes{' + BRIDGE_SEL + '}' + OWNER_JOIN, "{{bridge_id}} {{process}}")], 0, 61, unit="bytes"),
    panel("Bridge CPU (cores)", [('rate(heimdall_bridge_process_cpu_seconds_total{' + BRIDGE_SEL + '}[5m])' + OWNER_JOIN, "{{bridge_id}}")], 12, 61, unit="short"),
    panel("Instance RSS by provider", [('sum by (bridge_id, provider) (heimdall_instance_resident_bytes{' + BRIDGE_SEL + '})', "{{bridge_id}} {{provider}}")], 0, 69, unit="bytes"),
    panel("Instance CPU by provider (cores)", [('sum by (bridge_id, provider) (rate(heimdall_instance_cpu_seconds_total{' + BRIDGE_SEL + '}[5m]))', "{{bridge_id}} {{provider}}")], 12, 69, unit="short"),
    panel("Host memory available %", [('heimdall_bridge_host_memory_bytes{kind="available",' + BRIDGE_SEL + '} / on(bridge_id) heimdall_bridge_host_memory_bytes{kind="total"}', "{{bridge_id}}")], 0, 77, unit="percentunit", extra_fc={"min": 0, "max": 1}),
    panel("Host load1 / disk free", [
        ('heimdall_bridge_host_load1{' + BRIDGE_SEL + '}', "load1 {{bridge_id}}"),
        ('heimdall_bridge_disk_free_bytes{' + BRIDGE_SEL + '} / 1e9', "disk free GB {{bridge_id}}"),
    ], 12, 77, unit="short", desc="Disk is a panel, never a page: it is the customer's machine."),

    # bridge_logs plan v2 section 5: errors/h per bridge (one series per bridge,
    # no code) and the raw events of the selected bridge(s) from VictoriaLogs.
    row("Bridge errors (relayed events)", 85),
    panel("Errors/h per bridge (top 10)", [('topk(10, sum by (bridge_id) (increase(heimdall_bridge_errors_by_bridge_total{' + BRIDGE_SEL + '}[1h]))' + OWNER_JOIN + ')', "{{bridge_id}} {{owner}}")], 0, 86, unit="short",
          desc="Count-weighted warn+error events per bridge per hour (heimdall_bridge_errors_by_bridge_total). Codes are on the Bridge Events dashboard."),
    panel("Errors/s by code (fleet)", [('sum by (code) (rate(heimdall_bridge_errors_total[15m]))', "{{code}}")], 12, 86, unit="ops"),
    logs_panel("Recent events for the selected bridge(s)", '{job="heimdall-bridge"} bridge_id:~"$bridge"', 0, 94, w=24, h=12),

    # REQ-ERR-PROTO-B: error classes and overload signals end to end.
    row("Errors, retries and overload", 106),
    panel("API errors/s by class and code", [('sum by (class, code) (rate(heimdall_errors_total[5m]))', "{{class}} {{code}}")], 0, 107, unit="ops",
          desc="Hub API error answers (heimdall_errors_total). retriable = the caller may retry; recoverable = needs a user/config fix; fatal = give up."),
    panel("Bridge retries, shed load and open breakers", [
        ('sum by (outcome) (rate(heimdall_bridge_http_retries_total{' + BRIDGE_SEL + '}[5m]))', "http {{outcome}}"),
        ('sum by (outcome) (rate(heimdall_bridge_dispatch_total{outcome=~"shed|deadline_expired",' + BRIDGE_SEL + '}[5m]))', "dispatch {{outcome}}"),
        ('sum(rate(heimdall_bridge_breaker_trips_total{' + BRIDGE_SEL + '}[5m]))', "breaker trips"),
        ('sum(heimdall_bridge_breakers_open{' + BRIDGE_SEL + '})', "breakers open"),
    ], 12, 107, unit="short",
          desc="From bridge heartbeats. http retry/recovered/gave_up/deferred: bridge->hub HTTP retries; shed: commands refused busy; deadline_expired: dropped after the hub stopped waiting."),

    # Task System v2 row: added to fleet.json by hand in 45f4d179, now generated.
    row("Task System v2", 115),
    panel("Task Leases & Armed Timers", [('heimdall_task_lease_active', "lease: {{kind}}"), ('heimdall_task_timers_armed', "timers armed")], 0, 116, unit="short",
          desc="Live task leases by kind and armed timers",
          extra_fc={"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 15, "lineWidth": 2}}),
    panel("Task Engine Matcher & Transitions", [
        ('sum by (trigger) (rate(heimdall_task_matcher_runs_total[5m]))', "matcher: {{trigger}}"),
        ('sum(rate(heimdall_task_transitions_total[5m]))', "all transitions"),
    ], 12, 116, unit="ops", desc="Rate of matcher execution loops and state transitions",
          extra_fc={"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 2}}),
]

# The Task System v2 row's ids (62-64) were assigned by hand after streams and
# bridge-events had been generated; rewind so those dashboards keep their ids.
_id[0] -= 3

fleet = dict(dashboard)
fleet.update({
    "uid": "heimdall-fleet",
    "title": "Heimdall / Fleet",
    "panels": fleet_panels,
    "templating": {"list": [
        {"name": "owner", "type": "query", "datasource": DS, "query": "label_values(heimdall_bridge_info, owner)", "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "sort": 1},
        {"name": "bridge", "type": "query", "datasource": DS, "query": 'label_values(heimdall_bridge_info{owner=~"$owner"}, bridge_id)', "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "sort": 1},
    ]},
})
write("fleet.json", fleet)

# ---------------------------------------------------------------------------
# Streams & shells.
streams_panels = [
    row("WebSockets", 0),
    panel("Open connections by kind", [('heimdall_ws_connections', "{{kind}}")], 0, 1, unit="short"),
    panel("Connects/s by kind and result", [('sum by (kind, result) (rate(heimdall_ws_connections_total[5m]))', "{{kind}} {{result}}")], 12, 1, unit="ops"),
    panel("Disconnects/s by kind and reason", [('sum by (kind, reason) (rate(heimdall_ws_disconnects_total[5m]))', "{{kind}} {{reason}}")], 0, 9, unit="ops"),
    panel("Connection duration p50 by kind", [('histogram_quantile(0.5, sum by (kind, le) (rate(heimdall_ws_connection_duration_seconds_bucket[1h])))', "{{kind}}")], 12, 9, unit="s"),
    panel("Bytes/s by kind and direction", [('sum by (kind, direction) (rate(heimdall_ws_bytes_total[5m]))', "{{kind}} {{direction}}")], 0, 17, unit="Bps"),
    panel("Write errors/s", [('sum by (kind, reason) (rate(heimdall_ws_write_errors_total[5m]))', "{{kind}} {{reason}}")], 12, 17, unit="ops"),

    row("Shells", 25),
    panel("Shell sessions by state", [('sum by (state) (heimdall_shell_sessions)', "{{state}}")], 0, 26, unit="short"),
    panel("Shell viewers (total / top bridges)", [('sum(heimdall_shell_viewers)', "total"), ('topk(5, heimdall_shell_viewers)', "{{bridge_id}}")], 12, 26, unit="short"),
    panel("PTY output vs fan-out vs input (B/s)", [
        ('sum(rate(heimdall_shell_output_bytes_total[5m]))', "output (from bridges)"),
        ('rate(heimdall_shell_fanout_bytes_total[5m])', "fan-out (to viewers)"),
        ('rate(heimdall_shell_input_bytes_total[5m])', "input"),
    ], 0, 34, unit="Bps"),
    panel("Viewer detaches (15m) by reason", [('sum by (reason) (increase(heimdall_shell_viewer_detaches_total[15m]))', "{{reason}}")], 12, 34, unit="short"),
    panel("First-frame latency p50 / p95", [
        ('histogram_quantile(0.5, rate(heimdall_shell_first_frame_latency_seconds_bucket[15m]))', "p50"),
        ('histogram_quantile(0.95, rate(heimdall_shell_first_frame_latency_seconds_bucket[15m]))', "p95"),
    ], 0, 42, unit="s"),
    panel("Output bytes/s per bridge (top 10)", [('topk(10, rate(heimdall_shell_output_bytes_total[5m]))', "{{bridge_id}}")], 12, 42, unit="Bps"),

    row("Preview & LSP", 50),
    panel("Preview requests/s by status class", [('sum by (status_class) (rate(heimdall_preview_requests_total[5m]))', "{{status_class}}")], 0, 51, unit="reqps"),
    panel("Preview bytes/s", [('sum by (direction) (rate(heimdall_preview_bytes_total[5m]))', "{{direction}}")], 12, 51, unit="Bps"),
    panel("Active preview tunnels", [('sum(heimdall_preview_active_tunnels)', "total"), ('topk(5, heimdall_preview_active_tunnels)', "{{bridge_id}}")], 0, 59, unit="short"),
    panel("LSP sessions by language", [('heimdall_lsp_sessions', "{{language}}")], 12, 59, unit="short"),
]
streams = dict(dashboard)
streams.update({"uid": "heimdall-streams", "title": "Heimdall / Streams & Shells", "panels": streams_panels, "templating": {"list": []}})
write("streams.json", streams)

# ---------------------------------------------------------------------------
# Bridge Events (bridge_logs plan v2 section 5): what the relayed warn/error
# events say, fleet-wide and per bridge. Counters come from Prometheus; the
# event lines come from VictoriaLogs (optional; see README).
EV_SEL = 'code=~"$code",level=~"$level"'
LOGS_SEL = '{job="heimdall-bridge"} bridge_id:~"$bridge_id" code:~"$code" level:~"$level"'
events_panels = [
    row("Fleet", 0),
    panel("Errors/h by code", [('sum by (code) (increase(heimdall_bridge_errors_total{' + EV_SEL + '}[1h]))', "{{code}}", True)], 0, 1, w=12, h=10, kind="bargauge",
          options={"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
          desc="Count-weighted events in the last hour by code (heimdall_bridge_errors_total)."),
    panel("Errors/s by code", [('sum by (code) (rate(heimdall_bridge_errors_total{' + EV_SEL + '}[15m]))', "{{code}}")], 12, 1, w=12, h=10, unit="ops"),
    panel("Per-bridge rate (events/h, top 20)", [('topk(20, sum by (bridge_id) (increase(heimdall_bridge_errors_by_bridge_total{bridge_id=~"$bridge_id"}[1h]))' + ' * on(bridge_id) group_left(owner) heimdall_bridge_info' + ')', "", True)], 0, 11, w=12, h=10, kind="table",
          options={"sortBy": [{"displayName": "Value", "desc": True}]},
          desc="One series per bridge (no code). owner is joined from heimdall_bridge_info here only."),
    panel("Codes first seen in the last 24 h", [('count by (code) (heimdall_bridge_errors_total unless heimdall_bridge_errors_total offset 24h)', "{{code}}", True)], 12, 11, w=12, h=10, kind="table",
          desc="A code with no series 24 h ago: a new failure mode or a new bridge build. code=\"other\" means bridges newer than the hub."),
    panel("Ingest health", [
        ('sum by (reason) (rate(heimdall_bridge_frames_rejected_total{reason=~"log_.*"}[5m]))', "rejected {{reason}}"),
        ('rate(heimdall_bridge_log_dropped_total[5m])', "dropped on bridges"),
        ('rate(heimdall_bridge_log_queue_dropped_total[5m])', "dropped in hub queue"),
        ('rate(heimdall_log_push_failures_total[5m])', "push failures"),
    ], 0, 21, w=12, h=8, unit="ops"),
    panel("Entries accepted vs rows written", [
        ('rate(heimdall_bridge_log_entries_total[5m])', "entries (count-weighted)"),
        ('rate(heimdall_bridge_log_rows_written_total[5m])', "rows written"),
    ], 12, 21, w=12, h=8, unit="ops"),
    row("Events (VictoriaLogs)", 29),
    logs_panel("Event stream", LOGS_SEL, 0, 30, w=24, h=16,
               desc="LogsQL over the optional VictoriaLogs backend. Lines are rendered by the hub; bridge_id, code, version and the typed fields are structured metadata."),
]
events = dict(dashboard)
events.update({
    "uid": "heimdall-bridge-events",
    "title": "Heimdall / Bridge Events",
    "panels": events_panels,
    "time": {"from": "now-24h", "to": "now"},
    "templating": {"list": [
        {"name": "bridge_id", "type": "query", "datasource": DS, "query": "label_values(heimdall_bridge_info, bridge_id)", "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "sort": 1},
        {"name": "level", "type": "custom", "query": "warn,error", "includeAll": True, "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"},
         "options": [{"text": "All", "value": "$__all", "selected": True}, {"text": "warn", "value": "warn", "selected": False}, {"text": "error", "value": "error", "selected": False}]},
        {"name": "code", "type": "query", "datasource": DS, "query": "label_values(heimdall_bridge_errors_total, code)", "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "sort": 1},
    ]},
})
write("bridge-events.json", events)

# ---------------------------------------------------------------------------
# Hub DB: phase-1 DB latency / lock-contention telemetry
# (docs/reference/db-telemetry.md). Every query is scoped to the selected
# job + instance so other scrape targets never mix in. No `or vector(0)`:
# absent telemetry (HEIMDALL_DB_TELEMETRY=off, a pre-telemetry build, or no
# activity) shows "No data", never a fabricated zero.
HUB = 'job="$job",instance="$instance"'
NO_DB = "No data: telemetry off, pre-telemetry hub build, or no matching activity"


def sel(extra=""):
    return "{" + HUB + ("," + extra if extra else "") + "}"


# Selectors used inside f-strings (Python < 3.12 cannot nest the quote style).
S_CONN = sel('conn=~"$conn"')
S_CONN_READ = sel('conn=~"$conn",op="select"')
S_CONN_WRITE = sel('conn=~"$conn",op=~"insert|update|delete"')
S_MAIN = sel('conn="main"')
S_CONNLOCK = sel('lock=~"conn_.*"')
S_CONNLOCK_1MS = sel('lock=~"conn_.*",le="0.001"')
S_NO_BUSY_WAIT = sel('component!="busy_wait"')  # phase 1: busy_wait is always 0
S_NOT_COMMIT = sel('outcome!="commit"')
S_BUSY = sel('code=~"busy.*|locked"')
S_HIT = sel('kind="hit"')
S_HITMISS = sel('kind=~"hit|miss"')


def quantiles(bucket, by, extra="", legend=""):
    """p50/p95/p99 of one histogram, aggregated by `by` (plus le)."""
    return [(f'histogram_quantile({q}, sum by (le{", " + by if by else ""}) (rate({bucket}{sel(extra)}[5m])))', f"p{int(q * 100)} {legend}".strip())
            for q in (0.5, 0.95, 0.99)]


DB_GUIDE = """\
**Phase-1 DB telemetry** (`HEIMDALL_DB_TELEMETRY`, default `basic`). Reference: `docs/reference/db-telemetry.md`.

- **No data ≠ zero.** `off` (explicit opt-out) and hub builds without the telemetry register none of these families, so panels show *No data*. Lazy series (per route, call site, op, tx kind) also appear only after the first matching call.
- **Disjoint vs containing intervals.** `app_lock_wait`, `conn_wait` and `exec_excl_busy` never overlap on one thread: their *sums* may be stacked and divided by request time (ratio of sums). Lock **hold** and **transaction** durations *contain* the holder's waits and execution: they are never added to wait or request components.
- **Percentiles are per histogram.** Never subtract one percentile from another (e.g. hold p99 − wait p99); compare `_sum` rates instead. Quantiles interpolate inside buckets: wait buckets top out at 5 s, hold/tx at 30 s, exec at 5 s.
- **`busy_wait` is unavailable in phase 1** (no busy handler; `full` mode is rejected at boot). Successful `busy_timeout` sleeps are *inside* `exec` on write/tx ops, so `busy_wait` is hidden here rather than shown as a misleading 0.
- **Waiters:** `heimdall_db_lock_waiters` is sampled at scrape. `_waiters_max` is the high-water mark since the *previous scrape* and is reset by every scrape: exact with one scraper, a lower bound if anything else (e.g. a manual `curl`) also scrapes. Use contention rates for manual checks.
- **Cardinality:** call-site panels are `topk` over up to 3 × 261 `(conn, site)` series; keep their time range modest. WebSocket-frame DB time lands in scope `other` in phase 1.
- **Histogram layout change:** in `basic` the HTTP request histogram gains `le="0.0025"`; never take an HTTP quantile across the deploy. This dashboard only uses its `_sum`.
"""

db_stat = {**stat_opts}
db_panels = [
    row("Status and reading guide", 0),
    panel("DB telemetry", [(f'count(heimdall_sqlite_library_info{sel()})', "telemetry", True)], 0, 1, w=6, h=4, kind="stat", options=db_stat,
          no_value="off / not deployed",
          extra_fc={"mappings": [{"type": "range", "options": {"from": 1, "to": 1e9, "result": {"text": "basic (on)"}}}],
                    "color": {"mode": "fixed", "fixedColor": "green"}},
          desc="Present when the selected hub exposes heimdall_sqlite_library_info, i.e. runs with HEIMDALL_DB_TELEMETRY=basic (the default since the telemetry release). Absent = explicit off, an older build, or the scrape is down."),
    panel("Linked SQLite library", [(f'heimdall_sqlite_library_info{sel()}', "{{version}}", True)], 6, 1, w=6, h=4, kind="stat",
          options={**stat_opts, "textMode": "name"}, extra_fc={"color": {"mode": "fixed", "fixedColor": "text"}}, no_value=NO_DB,
          desc="sqlite3_libversion() of the library the hub process actually linked (not the sqlite3 CLI on the host)."),
    panel("Oldest open unit of work", [(f'heimdall_db_uow_oldest_hold_seconds{sel()}', "oldest UoW", True)], 12, 1, w=6, h=4, kind="stat", unit="s",
          options=stat_opts, no_value=NO_DB,
          extra_fc={"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]}},
          desc="Age of the currently open outer unit of work at the last scrape (0 = none open)."),
    panel("Slow-log records dropped (range)", [(f'sum by (reason) (increase(heimdall_db_slow_log_dropped_total{sel()}[$__range]))', "{{reason}}", True)], 18, 1, w=6, h=4, kind="stat",
          options={**stat_opts, "textMode": "value_and_name"}, no_value=NO_DB,
          desc="db_slow_request / db_slow_scope lines dropped by the 10 lines/s limiter over the selected range. reason=slow drops matter for slow-request criteria; the records themselves are in the hub's stderr/journal."),
    text_panel("How to read this dashboard", DB_GUIDE, 0, 5, w=24, h=11),

    row("Request DB time (disjoint components, ratio of sums)", 16),
    panel("Share of HTTP dispatch time by DB component", [
        (f'sum by (component) (rate(heimdall_http_request_db_seconds_total{S_NO_BUSY_WAIT}[5m]))'
         f' / on() group_left() sum(rate(heimdall_http_request_duration_seconds_sum{sel()}[5m]))', "{{component}}"),
    ], 0, 17, unit="percentunit", no_value=NO_DB,
          extra_fc={"min": 0, "custom": {"stacking": {"mode": "normal", "group": "A"}, "fillOpacity": 30}},
          desc="sum(DB component seconds) / sum(router dispatch seconds) over the same plain-HTTP requests. Components are disjoint per thread, so the stack is the DB share of request time; the rest is non-DB work. Transaction hold is NOT part of this. busy_wait is always 0 in phase 1 and is hidden."),
    panel("DB time per route, top 10 (DB-seconds per second)", [
        (f'topk(10, sum by (route) (rate(heimdall_http_request_db_seconds_total{sel()}[5m])))', "{{route}}"),
    ], 12, 17, unit="short", no_value=NO_DB,
          desc="Sum of the disjoint DB components per route pattern, in seconds of DB time per wall-clock second (can exceed 1 with concurrent requests). topk is evaluated per point, so more than 10 routes can appear over the range."),
    panel("DB share of route time (top 10 routes by DB time)", [
        (f'(sum by (route) (rate(heimdall_http_request_db_seconds_total{sel()}[5m])) / sum by (route) (rate(heimdall_http_request_duration_seconds_sum{sel()}[5m])))'
         f' and topk(10, sum by (route) (rate(heimdall_http_request_db_seconds_total{sel()}[5m])))', "{{route}}"),
    ], 0, 25, unit="percentunit", no_value=NO_DB, extra_fc={"min": 0},
          desc="Per route: sum of DB component seconds / sum of dispatch seconds (ratio of sums, never a ratio of percentiles), for the 10 routes with the most DB time at each point (more than 10 can appear over the range)."),
    panel("DB time per scope by component (DB-seconds per second)", [
        (f'sum by (scope, component) (rate(heimdall_db_scope_seconds_total{S_NO_BUSY_WAIT}[5m])) > 0', "{{scope}} {{component}}"),
    ], 12, 25, unit="short", no_value=NO_DB,
          desc="All scopes, including background work (timer, merge, bridge_log, shell, scrape) and unscoped work (other, which includes WebSocket frames in phase 1). Series are eager; idle scope/component pairs are filtered out with > 0."),

    row("Lock wait and hold", 33),
    panel("App lock wait p50 / p95 / p99", quantiles("heimdall_db_lock_wait_seconds_bucket", "lock", 'lock!~"conn_.*"', "{{lock}}"), 0, 34, unit="s", no_value=NO_DB,
          desc="Wait to acquire a DB-guarding service lock (uow_tx, billing, vault, enroll, collector, projector, reconfig, launch_prefs). Gaps mean no acquisitions in the window."),
    panel("Connection mutex wait p50 / p95 / p99", quantiles("heimdall_db_lock_wait_seconds_bucket", "lock", 'lock=~"conn_.*"', "{{lock}}"), 12, 34, unit="s", no_value=NO_DB,
          desc="Wait for the SQLite connection mutex (conn_main, conn_billing, conn_enroll, conn_vault, conn_metrics). Its hold time is the exec histogram below."),
    panel("App lock hold p50 / p95 / p99", quantiles("heimdall_db_lock_hold_seconds_bucket", "lock", "", "{{lock}}"), 0, 42, unit="s", no_value=NO_DB,
          desc="Time an app lock was held. Contains the holder's own waits and execution: never add it to wait times or subtract percentiles."),
    panel("Connection mutex: share of acquisitions waiting > 1 ms", [
        (f'1 - sum by (lock) (rate(heimdall_db_lock_wait_seconds_bucket{S_CONNLOCK_1MS}[5m]))'
         f' / sum by (lock) (rate(heimdall_db_lock_wait_seconds_count{S_CONNLOCK}[5m]))', "{{lock}}"),
    ], 12, 42, unit="percentunit", no_value=NO_DB, extra_fc={"min": 0, "max": 1}),
    panel("Contended acquisitions/s by lock", [(f'sum by (lock) (rate(heimdall_db_lock_contended_total{sel()}[5m]))', "{{lock}}")], 0, 50, unit="ops", no_value=NO_DB,
          desc="Acquisitions whose try-lock found the lock already held."),
    panel("Contended share of acquisitions by lock", [
        (f'sum by (lock) (rate(heimdall_db_lock_contended_total{sel()}[5m])) / sum by (lock) (rate(heimdall_db_lock_wait_seconds_count{sel()}[5m]))', "{{lock}}"),
    ], 12, 50, unit="percentunit", no_value=NO_DB, extra_fc={"min": 0, "max": 1}),
    panel("Lock waiters: sampled at scrape vs high-water between scrapes", [
        (f'max by (lock) (heimdall_db_lock_waiters{sel()})', "now {{lock}}"),
        (f'max by (lock) (max_over_time(heimdall_db_lock_waiters_max{sel()}[5m]))', "max {{lock}}"),
    ], 0, 58, unit="short", no_value=NO_DB,
          desc="'now' is the instantaneous depth at scrape time. 'max' is the high-water mark since the previous scrape; every scrape resets it, so a second scraper (manual curl) makes it a lower bound."),
    panel("Connection mutex queueing per second of execution", [
        (f'sum by (conn) (label_replace(rate(heimdall_db_lock_wait_seconds_sum{S_CONNLOCK}[5m]), "conn", "$1", "lock", "conn_(.*)"))'
         f' / sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum{sel()}[5m]))', "{{conn}}"),
    ], 12, 58, unit="short", no_value=NO_DB,
          desc="sum(conn mutex wait seconds) / sum(exec seconds) for the same connection: 1.0 means callers queue as long as SQLite executes."),

    row("Execution per connection ($conn)", 66),
    panel("Connection busy: exec seconds per second", [(f'sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum{S_CONN}[5m]))', "{{conn}}")], 0, 67,
          unit="percentunit", no_value=NO_DB, extra_fc={"min": 0},
          desc="Fraction of wall time the connection mutex is held by wrapped calls (step, exec, prepare, finalize). conn=other aggregates unregistered handles and can exceed 100 %."),
    panel("Exec time per step/exec call p50 / p95 / p99", quantiles("heimdall_sqlite_exec_seconds_bucket", "conn", 'conn=~"$conn",op!~"prepare|finalize"', "{{conn}}"), 12, 67, unit="s", no_value=NO_DB,
          desc="Time inside SQLite with the connection mutex held, per step or sqlite3_exec call (prepare/finalize excluded so cheap calls do not dominate p50; all statement ops incl. begin/commit are merged). Includes successful busy_timeout sleeps (phase 1 has no busy split)."),
    panel("Exec time by op (seconds per second)", [(f'sum by (conn, op) (rate(heimdall_sqlite_exec_seconds_sum{S_CONN}[5m]))', "{{conn}} {{op}}")], 0, 75,
          unit="short", no_value=NO_DB, extra_fc={"custom": {"stacking": {"mode": "normal", "group": "A"}, "fillOpacity": 30}}),
    panel("Statements/s by op", [(f'sum by (conn, op) (rate(heimdall_sqlite_statements_total{S_CONN}[5m]))', "{{conn}} {{op}}")], 12, 75,
          unit="ops", no_value=NO_DB, desc="Statement executions: the first step of each execution and one per sqlite3_exec call."),
    panel("Read / write mix of exec time", [
        (f'sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum{S_CONN_READ}[5m])) / sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum{S_CONN}[5m]))', "read (select) {{conn}}"),
        (f'sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum{S_CONN_WRITE}[5m])) / sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum{S_CONN}[5m]))', "write (insert/update/delete) {{conn}}"),
    ], 0, 83, unit="percentunit", no_value=NO_DB, extra_fc={"min": 0, "max": 1},
          desc="Share of exec seconds. The remainder is begin/commit/rollback/pragma/create/other/prepare/finalize."),
    panel("VM steps per statement by op", [
        (f'sum by (conn, op) (rate(heimdall_sqlite_vm_steps_total{S_CONN}[5m])) / sum by (conn, op) (rate(heimdall_sqlite_statements_total{S_CONN}[5m]))', "{{conn}} {{op}}"),
    ], 12, 83, unit="short", no_value=NO_DB, desc="Mean statement cost (sqlite3_stmt_status VM_STEP deltas per execution)."),
    panel("Full-scan steps/s and sorts/s by op", [
        (f'sum by (conn, op) (rate(heimdall_sqlite_fullscan_steps_total{S_CONN}[5m])) > 0', "fullscan {{conn}} {{op}}"),
        (f'sum by (conn, op) (rate(heimdall_sqlite_sort_total{S_CONN}[5m])) > 0', "sort {{conn}} {{op}}"),
    ], 0, 91, unit="ops", no_value=NO_DB),
    panel("Wrapped calls/s by op", [(f'sum by (conn, op) (rate(heimdall_sqlite_exec_seconds_count{S_CONN}[5m]))', "{{conn}} {{op}}")], 12, 91,
          unit="ops", no_value=NO_DB, desc="Every wrapped step/exec/prepare/finalize call (one statement takes several steps)."),

    row("Transactions", 99),
    panel("Transactions/s by kind, rw and outcome", [
        (f'sum by (kind, rw, outcome) (rate(heimdall_db_tx_duration_seconds_count{sel()}[5m]))', "{{kind}} {{rw}} {{outcome}}"),
        (f'rate(heimdall_db_uow_nested_total{sel()}[5m])', "nested UoW (savepoint)"),
    ], 0, 100, unit="ops", no_value=NO_DB,
          desc="Outer transactions only; nested units of work are savepoints, counted separately and never as a second transaction. rw=write when the UoW ran an insert/update/delete step."),
    panel("Committed transaction duration p50 / p95 / p99 by kind", quantiles("heimdall_db_tx_duration_seconds_bucket", "kind", 'outcome="commit"', "{{kind}}"), 12, 100, unit="s", no_value=NO_DB,
          desc="outcome=commit only (begin_failed/rollback durations would skew it; read and write units are merged). BEGIN to COMMIT return (excludes after-commit hooks; dedicated conns start when BEGIN returns). Contains waits and exec: never add to request components."),
    panel("Rolled back / failed transactions/s", [
        (f'sum by (kind, outcome) (rate(heimdall_db_tx_duration_seconds_count{S_NOT_COMMIT}[5m]))', "{{kind}} {{outcome}}"),
    ], 0, 108, unit="ops", no_value=NO_DB),
    panel("Oldest open unit of work (max over 5m)", [(f'max_over_time(heimdall_db_uow_oldest_hold_seconds{sel()}[5m])', "oldest UoW")], 12, 108, unit="s", no_value=NO_DB),

    row("Call sites ($conn, selected time range)", 116),
    panel("Top 10 call sites by step exec time", [(f'topk(10, sum by (conn, site) (increase(heimdall_sqlite_site_exec_seconds_total{S_CONN}[$__range])))', "{{conn}} {{site}}", True)],
          0, 117, w=8, h=10, kind="bargauge", unit="s", no_value=NO_DB,
          options={"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
          desc="site = <file>:<procedure> of the caller; step calls only. Up to 3 x 261 series are scanned: keep the range modest."),
    panel("Top 10 call sites by full-scan steps", [(f'topk(10, sum by (conn, site) (increase(heimdall_sqlite_site_fullscan_steps_total{S_CONN}[$__range])))', "{{conn}} {{site}}", True)],
          8, 117, w=8, h=10, kind="bargauge", unit="short", no_value=NO_DB,
          options={"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}),
    panel("Top 10 call sites by VM steps", [(f'topk(10, sum by (conn, site) (increase(heimdall_sqlite_site_vm_steps_total{S_CONN}[$__range])))', "{{conn}} {{site}}", True)],
          16, 117, w=8, h=10, kind="bargauge", unit="short", no_value=NO_DB,
          options={"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}),
    panel("Top-3 call sites' share of main-connection step time", [
        (f'sum(topk(3, sum by (site) (increase(heimdall_sqlite_site_exec_seconds_total{S_MAIN}[$__range]))))'
         f' / sum(increase(heimdall_sqlite_site_exec_seconds_total{S_MAIN}[$__range]))', "top-3 share", True),
    ], 0, 127, w=24, h=4, kind="stat", unit="percentunit", options=stat_opts, no_value=NO_DB,
          desc="sum of the 3 largest main-connection call sites / all main-connection step exec time over the selected range."),

    row("Errors, cache and storage", 131),
    panel("SQLite errors/s by conn, op and code", [(f'sum by (conn, op, code) (rate(heimdall_sqlite_errors_total{sel()}[5m]))', "{{conn}} {{op}} {{code}}")], 0, 132, unit="ops", no_value=NO_DB,
          desc="Error return codes from wrapped step/exec/prepare calls (finalize never double-counts)."),
    panel("Busy / locked errors: new family vs legacy counter", [
        (f'sum by (conn, code) (rate(heimdall_sqlite_errors_total{S_BUSY}[5m]))', "{{conn}} {{code}}"),
        (f'sum(rate(heimdall_sqlite_busy_total{sel()}[5m]))', "legacy heimdall_sqlite_busy_total"),
    ], 12, 132, unit="ops", no_value="No data: no busy/locked errors recorded or telemetry absent",
          desc="Failed busy waits only: successful busy_timeout sleeps are inside exec and invisible in phase 1. The legacy counter exists in both modes."),
    panel("Page cache events/s by conn and kind", [(f'sum by (conn, kind) (rate(heimdall_sqlite_cache_events_total{sel()}[5m]))', "{{conn}} {{kind}}")], 0, 140, unit="ops", no_value=NO_DB,
          desc="sqlite3_db_status per open handle, summed per connection kind. Counts restart when a handle closes (rate() treats that as a counter reset)."),
    panel("Page cache hit ratio by conn", [
        (f'sum by (conn) (rate(heimdall_sqlite_cache_events_total{S_HIT}[5m])) / sum by (conn) (rate(heimdall_sqlite_cache_events_total{S_HITMISS}[5m]))', "{{conn}}"),
    ], 12, 140, unit="percentunit", no_value=NO_DB, extra_fc={"min": 0, "max": 1}),
    panel("Slow-log records dropped/s by reason", [(f'sum by (reason) (rate(heimdall_db_slow_log_dropped_total{sel()}[5m]))', "{{reason}}")], 0, 148, unit="ops", no_value=NO_DB),
    panel("Database and WAL file size", [
        (f'heimdall_sqlite_db_bytes{sel()}', "db"),
        (f'heimdall_sqlite_wal_bytes{sel()}', "wal"),
    ], 12, 148, unit="bytes", desc="Legacy gauges (present with telemetry off too)."),
]

hub_db = dict(dashboard)
hub_db.update({
    "uid": "heimdall-hub-db",
    "title": "Heimdall / Hub DB",
    "tags": ["heimdall", "db"],
    "panels": db_panels,
    "templating": {"list": [
        {"name": "job", "label": "job", "type": "query", "datasource": DS, "query": "label_values(heimdall_hub_build_info, job)", "refresh": 2, "includeAll": False, "multi": False,
         "current": {"text": "heimdall-hub", "value": "heimdall-hub"}, "sort": 1},
        {"name": "instance", "label": "hub instance", "type": "query", "datasource": DS, "query": 'label_values(heimdall_hub_build_info{job="$job"}, instance)', "refresh": 2, "includeAll": False, "multi": False, "sort": 1},
        {"name": "conn", "label": "connection", "type": "custom", "query": "main,billing,enroll,vault,metrics,other", "includeAll": True, "multi": True, "allValue": ".*",
         "current": {"text": ["main"], "value": ["main"]},
         "options": [{"text": c, "value": c, "selected": c == "main"} for c in ["All", "main", "billing", "enroll", "vault", "metrics", "other"]]},
    ]},
})
hub_db["templating"]["list"][2]["options"][0]["value"] = "$__all"
write("hub-db.json", hub_db)
