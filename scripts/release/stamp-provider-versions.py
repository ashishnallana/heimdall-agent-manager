#!/usr/bin/env python3
"""Stamp provider packages and append catalog migrations without rewriting history."""
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys

PROVIDERS = ("antigravity", "claude", "codex")
MANIFESTS = ("antigravity/plugin.json", "claude-code/.claude-plugin/plugin.json",
             "codex/.codex-plugin/plugin.json")
CATALOG_SQL = re.compile(
    r"^(?:CREATE TABLE(?: IF NOT EXISTS)?|ALTER TABLE|INSERT(?: OR \w+)? INTO|UPDATE|DELETE FROM)"
    r"\s+(?:provider_catalog|provider_models|provider_catalog_meta|provider_icons)\b", re.I)
ORDER = re.compile(r"(migration_order :: \[)(\d+)(\]string \{)(.*?)(\n\})", re.S)


def catalog_database(directory, names):
    """Replay catalog statements only: other schemas have runtime upgrade twins."""
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    for name in names:
        statement = ""
        for line in (directory / name).read_text().splitlines(keepends=True):
            statement += line
            if not sqlite3.complete_statement(statement):
                continue
            clean = re.sub(r"(?m)^\s*--[^\n]*", "\n", statement).strip()
            if CATALOG_SQL.match(clean):
                db.executescript(statement)
            statement = ""
        if statement.strip() and re.sub(r"(?m)^\s*--[^\n]*", "", statement).strip():
            raise ValueError("Unterminated migration SQL: " + name)
    return db


def catalog_etag(db):
    # Keep field order and raw JSON whitespace identical to
    # src/hub/service/provider/provider_service.odin:write_catalog_entry_json.
    fields = ("provider", "display_name", "icon_url", "binary", "base_args", "yolo_args",
              "ask_args", "model_flag", "prompt_args", "prompt_delivery", "starter_prompt",
              "bootstrap_file", "skill_dir", "startup_detection", "activity_detection",
              "extension", "state")
    raw = {"base_args", "yolo_args", "ask_args", "prompt_args", "startup_detection",
           "activity_detection", "extension"}
    encode = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    entries = []
    for row in db.execute("SELECT * FROM provider_catalog ORDER BY rank ASC, provider ASC"):
        parts = []
        for field in fields:
            value = row[field]
            if field == "extension":
                value = value or "null"
            elif field == "ask_args":
                value = value or "[]"
            parts.append(encode(field) + ":" + (value if field in raw else encode(value)))
        models = [dict(row) for row in db.execute(
            "SELECT model_id, label, state FROM provider_models WHERE provider=? ORDER BY rank ASC, model_id ASC",
            (row["provider"],))]
        entries.append("{" + ",".join(parts) + ',"models":' + encode(models) + "}")
    body = '{"providers":[' + ",".join(entries) + "]}"
    return "sha256:" + hashlib.sha256(body.encode()).hexdigest()


def stamp(root, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
        raise ValueError("Invalid release version: " + version)
    extensions = root / "extensions"
    updates = {}
    for name in MANIFESTS:
        path = extensions / name
        value = json.loads(path.read_text())
        value["version"] = version
        updates[path] = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    # The Claude marketplace declares package versions; Codex currently does not.
    for name in (".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json"):
        path = extensions / name
        value = json.loads(path.read_text())
        if "version" in value:
            value["version"] = version
        if "version" in value.get("metadata", {}):
            value["metadata"]["version"] = version
        for plugin in value["plugins"]:
            if "version" in plugin:
                plugin["version"] = version
        updates[path] = json.dumps(value, indent=2, ensure_ascii=False) + "\n"

    directory = root / "src/hub/repository/sqlite/migrations"
    registry = directory.parent / "migrations.odin"
    text = registry.read_text()
    order = ORDER.search(text)
    if order is None:
        raise ValueError("Cannot find migration_order registry")
    names = re.findall(r'"([^"]+\.sql)"', order[4])
    if len(names) != int(order[2]) or len(names) != len(set(names)):
        raise ValueError("Inconsistent migration_order registry")
    numbered = {p.name for p in directory.glob("[0-9]*_*.sql")}
    if numbered != set(names):
        raise ValueError("Unregistered/missing migrations; resolve numbering collisions before bumping")

    with closing(catalog_database(directory, names)) as db:
        versions = {row[0]: json.loads(row[1])["min_version"] for row in db.execute(
            "SELECT provider, extension FROM provider_catalog WHERE provider IN ('antigravity','claude','codex')")}
        if set(versions) != set(PROVIDERS):
            raise ValueError("Missing shipped provider catalog entries")
        if any(value != version for value in versions.values()):
            patch = json.dumps({"min_version": version}, separators=(",", ":"))
            update = ("UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), "
                      + "'" + patch + "')\nWHERE provider IN ('antigravity', 'claude', 'codex');\n")
            db.executescript(update)
            etag = catalog_etag(db)
            number = max(int(name.split("_", 1)[0]) for name in numbered) + 1
            name = f"{number:03d}_extension_version_sync_{version.replace('.', '_').replace('-', '_')}.sql"
            symbol = f"MIGRATION_{number:03d}_EXTENSION_VERSION_SYNC"
            if symbol in text or (directory / name).exists():
                raise ValueError("Migration identity collision: " + name)
            sql = ("-- Generated by bump-version.sh; append-only provider release synchronization.\n"
                   "BEGIN IMMEDIATE;\n" + update + "DELETE FROM provider_catalog_meta;\n"
                   "INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('" + etag + "');\nCOMMIT;\n")
            # Register the same bytes for embedded and on-disk migration paths.
            declaration = symbol + ' :: #load("migrations/' + name + '", string)\n\n'
            text = text[:order.start()] + declaration + text[order.start():]
            order = ORDER.search(text)
            text = (text[:order.start()] + order[1] + str(len(names) + 1) + order[3] +
                    order[4] + '\n\t"' + name + '",' + order[5] + text[order.end():])
            # Put the lookup beside the generated #load, before the historical
            # migration_order declaration; use the existing embedded resolver body.
            resolver = re.search(r'(\n[ \t]*if name == "[^"]+\.sql" do return strings.clone\()', text)
            if resolver is None:
                raise ValueError("Cannot find embedded migration resolver")
            text = text[:resolver.start()] + '\n\tif name == "' + name + '" do return strings.clone(' + symbol + ')' + text[resolver.start():]
            updates[directory / name] = sql
            updates[registry] = text

    # All inputs and registry changes are validated before the first write.
    for path, content in updates.items():
        if not path.exists() or path.read_text() != content:
            path.write_text(content)


if __name__ == "__main__":
    try:
        stamp(Path(__file__).resolve().parents[2], sys.argv[1])
    except (OSError, ValueError, KeyError, sqlite3.Error) as error:
        sys.exit("Provider version synchronization failed: " + str(error))
