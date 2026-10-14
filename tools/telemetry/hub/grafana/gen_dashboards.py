#!/usr/bin/env python3
"""Generate the Heimdall Grafana dashboards (hub-health, fleet, streams, bridge-events).

Hand-maintaining Grafana JSON is error-prone; this script is the source of
truth for the Hub Health dashboard. Re-run it and commit the JSON when panels
change:  python3 tools/telemetry/hub/grafana/gen_dashboards.py
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


def panel(title, exprs, x, y, w=12, h=8, unit="short", kind="timeseries", desc="", extra_fc=None, options=None, ds=None):
    target.n = 0
    targets = [target(*e) if isinstance(e, tuple) else target(e) for e in exprs]
    if ds is not None:
        for t in targets:
            t["datasource"] = ds
    fc = {"defaults": {"unit": unit}, "overrides": []}
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
]

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
