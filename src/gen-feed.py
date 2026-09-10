#!/usr/bin/env python3
"""Generate the packages RSS feed from CI build results.

Usage:
    gen-feed.py update FEED_XML RESULTS_DIR RUN_ID [RUN_DATE] [SRCPKGS_DIR]

Reads per-arch build result files (`build-results-<ARCH>/results.tsv`,
lines `name<TAB>version<TAB>status`) produced by `build-packages.sh`,
and for every package that built successfully (`ok`) in this run adds or
updates one RSS item (guid = `name-version`), then writes an RSS 2.0 feed
to FEED_XML.

Items for packages not touched by the run are kept, so the feed
accumulates a release history. A same-version rebuild updates the item in
place; a version bump creates a new item. The feed is sorted newest first
and capped at MAX_ITEMS (1000) entries.

Optional template metadata (homepage, short_desc) is read from
SRCPKGS_DIR/<pkg>/template to fill the item link and description.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
from email.utils import format_datetime
from xml.etree import ElementTree

MAX_ITEMS = 1000

GH_REPO = "https://github.com/oSoWoSo/Void_Community_Repository"
CB_REPO = "https://codeberg.org/oSoWoSo/oco"
BRANCH = "OCO"

ITEM_FIELDS = ("title", "link", "pubDate", "description")

EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)


def _usage(err: str = "") -> int:
    if err:
        sys.stderr.write(f"error: {err}\n")
    sys.stderr.write(
        f"Usage: {sys.argv[0]} update FEED_XML RESULTS_DIR RUN_ID [RUN_DATE] [SRCPKGS_DIR]\n"
    )
    return 2


def esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def cdata(s: str) -> str:
    return "<![CDATA[" + s.replace("]]>", "]]&gt;") + "]]>"


def collect_results(results_dir: str) -> dict[str, dict]:
    """Return {pkg: {"version": str, "arches": set[str]}} for `ok` results."""
    data: dict[str, dict] = {}
    if not os.path.isdir(results_dir):
        return data
    for d in sorted(os.listdir(results_dir)):
        if not d.startswith("build-results-"):
            continue
        entry = os.path.join(results_dir, d)
        if not os.path.isdir(entry):
            continue
        arch = d[len("build-results-"):]
        tsv = os.path.join(entry, "results.tsv")
        if not os.path.isfile(tsv):
            continue
        with open(tsv, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) != 3:
                    sys.stderr.write(f"warning: bad line in {tsv}: {line!r}\n")
                    continue
                pkg, version, status = parts
                if status != "ok":
                    continue
                rec = data.setdefault(pkg, {"version": version, "arches": set()})
                rec["version"] = version
                rec["arches"].add(arch)
    return data


def read_template(srcpkgs_dir: str, pkg: str) -> tuple[str, str]:
    """Return (homepage, short_desc) from the template file, quotes stripped."""
    homepage = ""
    short_desc = ""
    path = os.path.join(srcpkgs_dir, pkg, "template")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip()
                if not homepage and line.startswith("homepage="):
                    homepage = line.split("=", 1)[1].strip().strip('"\'')
                elif not short_desc and line.startswith("short_desc="):
                    short_desc = line.split("=", 1)[1].strip().strip('"\'')
    except OSError:
        pass
    return homepage, short_desc


def _parse_date(value: str) -> dt.datetime:
    # Dates are stored as RFC-2822 at 00:00 UTC; the leading YYYY-MM-DD
    # part is all that matters for ordering.
    m = re.match(r"(?P<d>\d{4}-\d{2}-\d{2})", value or "")
    if m:
        try:
            return dt.datetime(*map(int, m.group("d").split("-")), tzinfo=dt.timezone.utc)
        except ValueError:
            pass
    return EPOCH


def parse_feed(path: str) -> dict[str, dict]:
    """Load existing items keyed by guid. Missing/corrupt feed -> {}."""
    items: dict[str, dict] = {}
    if not os.path.isfile(path):
        return items
    try:
        root = ElementTree.parse(path).getroot()
    except (ElementTree.ParseError, OSError):
        return items
    for item in root.iter("item"):
        guid_el = item.find("guid")
        if guid_el is None or not guid_el.text:
            continue
        rec = {"guid": guid_el.text}
        for field in ITEM_FIELDS:
            el = item.find(field)
            rec[field] = el.text if el is not None and el.text is not None else ""
        items[rec["guid"]] = rec
    return items


def default_srcpkgs(feed_path: str) -> str:
    """Guess the srcpkgs checkout location relative to the feed file."""
    candidate = os.path.abspath(os.path.join(os.path.dirname(feed_path), "..", "srcpkgs"))
    if os.path.isdir(candidate):
        return candidate
    return "srcpkgs"


def update_feed(
    feed_path: str, results_dir: str, run_id: str, run_date: str, srcpkgs_dir: str
) -> int:
    parsed_date: dt.datetime
    if run_date:
        parsed_date = dt.datetime.strptime(run_date, "%Y-%m-%d").replace(
            tzinfo=dt.timezone.utc
        )
    else:
        parsed_date = dt.datetime.now(dt.timezone.utc)
        run_date = parsed_date.date().isoformat()

    items = parse_feed(feed_path)
    changed = 0
    results = collect_results(results_dir)
    for pkg in sorted(results):
        rec = results[pkg]
        version = rec["version"]
        guid = f"{pkg}-{version}"
        homepage, short_desc = read_template(srcpkgs_dir, pkg)
        run_url = f"{GH_REPO}/actions/runs/{run_id}"
        arches = ", ".join(sorted(rec["arches"]))
        desc = (
            f"{short_desc}<br/>"
            f"Built on: {run_date}<br/>"
            f"Arches: {arches}<br/>"
            f'<a href="{run_url}">CI run</a>'
            f' &middot; <a href="{GH_REPO}/blob/{BRANCH}/srcpkgs/{pkg}/template">template</a>'
            f' &middot; <a href="{CB_REPO}/src/branch/{BRANCH}/srcpkgs/{pkg}/template">template (codeberg)</a>'
        )
        item = items.get(guid)
        if item is None:
            item = {"guid": guid}
            items[guid] = item
            changed += 1
        item["title"] = f"{pkg} {version}"
        item["link"] = homepage or run_url
        item["pubDate"] = format_datetime(parsed_date)
        item["description"] = desc
    write_feed(feed_path, items)
    return changed


def _items_sorted(items: dict[str, dict]) -> list[dict]:
    return sorted(
        items.values(),
        key=lambda r: (_parse_date(r.get("pubDate", "")), r.get("title", "")),
        reverse=True,
    )


def write_feed(path: str, items: dict[str, dict]) -> None:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<rss version="2.0">',
        "  <channel>",
        "    <title>Void Community Repository - Package updates</title>",
        f"    <link>{GH_REPO}</link>",
        "    <description>Newly built binary packages in the Void Community Repository</description>",
        "    <language>en-us</language>",
        f"    <lastBuildDate>{format_datetime(dt.datetime.now(dt.timezone.utc))}</lastBuildDate>",
        "    <generator>oco gen-feed.py</generator>",
    ]
    for rec in _items_sorted(items)[:MAX_ITEMS]:
        lines.append("    <item>")
        for field in ITEM_FIELDS:
            value = rec.get(field, "")
            if field == "description":
                lines.append(f"      <description>{cdata(value)}</description>")
            else:
                lines.append(f"      <{field}>{esc(value)}</{field}>")
        lines.append(f'      <guid isPermaLink="false">{esc(rec.get("guid", ""))}</guid>')
        lines.append("    </item>")
    lines.extend(["  </channel>", "</rss>", ""])
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp, path)


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 4 or args[0] != "update":
        return _usage()
    args = args[1:]
    feed_path, results_dir, run_id = args[0], args[1], args[2]
    run_date = args[3] if len(args) > 3 else ""
    srcpkgs_dir = args[4] if len(args) > 4 else default_srcpkgs(feed_path)
    if not os.path.isdir(srcpkgs_dir):
        sys.stderr.write(f"warning: srcpkgs dir not found: {srcpkgs_dir}\n")
    changed = update_feed(feed_path, results_dir, run_id, run_date, srcpkgs_dir)
    print(f"  feed: {changed} new items, {len(parse_feed(feed_path))} total in {feed_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())