#!/usr/bin/env python3
"""Generate Noctalia v5 root catalog.toml from */plugin.toml."""

from __future__ import annotations

import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT_DIR / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)
OLDEST_SUPPORTED_PLUGIN_API = 3


def git_commit_time(path: Path, *extra_args: str) -> int | None:
    res = subprocess.run(
        ["git", "-C", str(ROOT_DIR), "log", "-1", *extra_args, "--format=%ct", "--", str(path.relative_to(ROOT_DIR))],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        return None
    out = res.stdout.strip()
    return int(out) if out else None


def git_output(*args: str) -> str:
    res = subprocess.run(
        ["git", "-C", str(ROOT_DIR), *args],
        capture_output=True,
        text=True,
    )
    return res.stdout if res.returncode == 0 else ""


def plugin_history(subdir: str) -> list[tuple[str, int, dict]]:
    history: list[tuple[str, int, dict]] = []
    revisions = git_output("log", "--format=%H %ct", "--", f"{subdir}/plugin.toml").splitlines()
    for line in revisions:
        revision, _, commit_time = line.partition(" ")
        if not revision or not commit_time:
            continue
        raw = git_output("show", f"{revision}:{subdir}/plugin.toml")
        if not raw:
            continue
        try:
            manifest = tomllib.loads(raw)
        except tomllib.TOMLDecodeError:
            continue
        history.append((revision, int(commit_time), manifest))
    return history


def release_times(history: list[tuple[str, int, dict]]) -> dict[str, int]:
    times: dict[str, int] = {}
    for _, commit_time, manifest in reversed(history):
        version = manifest.get("version")
        if isinstance(version, str) and version:
            times.setdefault(version, commit_time)
    return times


def release_history(history: list[tuple[str, int, dict]], tip_api: int, released: dict[str, int]) -> list[dict]:
    releases: list[dict] = []
    lowest_api = tip_api
    for revision, _, manifest in history:
        if lowest_api <= OLDEST_SUPPORTED_PLUGIN_API:
            break
        plugin_api = manifest.get("plugin_api")
        version = manifest.get("version")
        if not isinstance(plugin_api, int) or isinstance(plugin_api, bool):
            continue
        if not isinstance(version, str) or not version:
            continue
        if plugin_api >= lowest_api or plugin_api < OLDEST_SUPPORTED_PLUGIN_API:
            continue
        releases.append(
            {
                "plugin_api": plugin_api,
                "version": version,
                "rev": revision,
                "updated_at": released[version],
            }
        )
        lowest_api = plugin_api
    return releases


def load_plugin_manifest(path: Path) -> dict:
    with path.open("rb") as handle:
        manifest = tomllib.load(handle)

    missing = [field for field in REQUIRED_FIELDS if field not in manifest]
    if missing:
        raise ValueError(f"{path.relative_to(ROOT_DIR)} is missing: {', '.join(missing)}")

    plugin_api = manifest["plugin_api"]
    if not isinstance(plugin_api, int) or isinstance(plugin_api, bool) or plugin_api <= 0:
        raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid plugin_api")

    if not isinstance(manifest["tags"], list) or not all(isinstance(tag, str) for tag in manifest["tags"]):
        raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid tags")

    out = {field: manifest[field] for field in REQUIRED_FIELDS}
    for field in OPTIONAL_STRING_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], str):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid {field}")
            out[field] = manifest[field]
    for field in OPTIONAL_BOOL_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], bool):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid {field}")
            out[field] = manifest[field]

    mtime = int(path.stat().st_mtime)
    out["updated_at"] = git_commit_time(path) or mtime
    out["added_at"] = git_commit_time(path, "--diff-filter=A") or out["updated_at"]
    return out


def existing_catalog_order() -> dict[str, int]:
    if not CATALOG_PATH.exists():
        return {}
    content = CATALOG_PATH.read_text(encoding="utf-8")
    ids = re.findall(r'(?m)^id\s*=\s*"([^"]+)"', content)
    return {plugin_id: index for index, plugin_id in enumerate(ids)}


def discover_plugins() -> list[dict]:
    order = existing_catalog_order()
    plugins: list[dict] = []
    for manifest_path in sorted(ROOT_DIR.glob("*/plugin.toml")):
        manifest = load_plugin_manifest(manifest_path)
        directory = manifest_path.parent.name
        history = plugin_history(directory)
        released = release_times(history)
        manifest["_directory"] = directory
        manifest["_order"] = order.get(manifest["id"], len(order))
        manifest["updated_at"] = released.get(manifest["version"], manifest["updated_at"])
        manifest["releases"] = release_history(history, manifest["plugin_api"], released)
        plugins.append(manifest)
    plugins.sort(key=lambda plugin: (plugin["_order"], plugin["_directory"]))
    return plugins


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_bool(value: bool) -> str:
    return "true" if value else "false"


def render_catalog(plugins: list[dict]) -> str:
    lines = [
        "# This file is auto-generated by scripts/update-catalog.py.",
        "# Noctalia plugins catalog.",
        "",
    ]
    for index, plugin in enumerate(plugins):
        if index:
            lines.append("")
        lines.extend(
            [
                "[[plugin]]",
                f"id = {toml_string(plugin['id'])}",
                f"name = {toml_string(plugin['name'])}",
                f"version = {toml_string(plugin['version'])}",
                f"updated_at = {plugin['updated_at']}",
                f"added_at = {plugin['added_at']}",
                f"author = {toml_string(plugin['author'])}",
            ]
        )
        if "license" in plugin:
            lines.append(f"license = {toml_string(plugin['license'])}")
        if "icon" in plugin:
            lines.append(f"icon = {toml_string(plugin['icon'])}")
        if "description" in plugin:
            lines.append(f"description = {toml_string(plugin['description'])}")
        if "deprecated" in plugin:
            lines.append(f"deprecated = {toml_bool(plugin['deprecated'])}")
        lines.extend(
            [
                f"plugin_api = {plugin['plugin_api']}",
                "tags = [" + ", ".join(toml_string(tag) for tag in plugin["tags"]) + "]",
            ]
        )
        for release in plugin["releases"]:
            lines.extend(
                [
                    "",
                    "[[plugin.release]]",
                    f"plugin_api = {release['plugin_api']}",
                    f"version = {toml_string(release['version'])}",
                    f"updated_at = {release['updated_at']}",
                    f"rev = {toml_string(release['rev'])}",
                ]
            )
    return "\n".join(lines) + "\n"


def main() -> int:
    plugins = discover_plugins()
    CATALOG_PATH.write_text(render_catalog(plugins), encoding="utf-8")
    print(f"Updated {CATALOG_PATH.relative_to(ROOT_DIR)} with {len(plugins)} plugin(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
