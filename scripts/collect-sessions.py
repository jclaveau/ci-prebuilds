#!/usr/bin/env python3
"""Record what the coding agents spent on this repo, from their local logs.

Writes metrics/sessions/YYYY-MM.jsonl, one row per billed request, alongside
the CI stores. Deliberately a separate script from collect-metrics.py: this
data lives only on the developer's machine, so the weekly GitHub workflow can
never gather it and there is no point giving it a command there.

Two sources, both read-only:

  claude-code  ~/.claude/projects/<slug>/*.jsonl — one JSON line per event;
               assistant events carry `message.usage`. The billing unit is the
               request, so rows are deduped on `requestId`: a request whose
               work spanned several internal iterations reports the SUM in the
               top-level usage, and the per-iteration entries would double it.
  opencode     ~/.local/share/opencode/opencode.db — sqlite. Assistant messages
               carry `data.tokens` and `data.cost`. Opened read-only; the app
               may well be running.

Cost is computed rather than trusted. Claude Code stores no price, and the
multipliers are not uniform — a 1-hour cache write is 2x base input while a
5-minute write is 1.25x, and the two are separate fields in the same record.
Fast mode re-prices input and output entirely. Getting that wrong quietly
misstates the number the whole exercise is about.

Usage:
    collect-sessions.py [--project PATH] [--all-projects]
"""
import argparse
import json
import glob
import os
import pathlib
import sqlite3
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "metrics"

# platform.claude.com/docs/en/about-claude/pricing, read 2026-08-14. USD per
# million tokens: (base input, 5m cache write, 1h cache write, cache read,
# output). Cache multipliers are 1.25x / 2x / 0.1x of base input, but they are
# written out rather than derived so a future model that breaks the pattern is
# a data change and not a silent error.
PRICES = {
    "claude-opus-5":     (5.0, 6.25, 10.0, 0.50, 25.0),
    "claude-opus-4-8":   (5.0, 6.25, 10.0, 0.50, 25.0),
    "claude-opus-4-7":   (5.0, 6.25, 10.0, 0.50, 25.0),
    "claude-opus-4-6":   (5.0, 6.25, 10.0, 0.50, 25.0),
    "claude-opus-4-5":   (5.0, 6.25, 10.0, 0.50, 25.0),
    "claude-sonnet-5":   (2.0, 2.50, 4.0, 0.20, 10.0),
    "claude-sonnet-4-6": (3.0, 3.75, 6.0, 0.30, 15.0),
    "claude-sonnet-4-5": (3.0, 3.75, 6.0, 0.30, 15.0),
    "claude-haiku-4-5":  (1.0, 1.25, 2.0, 0.10, 5.0),
    "claude-fable-5":    (10.0, 12.50, 20.0, 1.0, 50.0),
}
# Fast mode is a different price for input and output; the cache multipliers
# still apply on top of the fast base rate.
FAST_PRICES = {
    "claude-opus-5":   (10.0, 12.50, 20.0, 1.0, 50.0),
    "claude-opus-4-8": (10.0, 12.50, 20.0, 1.0, 50.0),
}
WEB_SEARCH_USD = 10.0 / 1000        # per search
INFERENCE_GEO_US_MULTIPLIER = 1.1   # US-pinned inference, Claude 4.6+


def normalize_model(model):
    """`claude-opus-5[1m]` and `claude-haiku-4-5-20251001` both price as their
    base model: the 1M-context suffix carries no premium, and a dated snapshot
    is the same model."""
    if not model:
        return None
    name = model.split("[")[0]
    for known in PRICES:
        if name == known or name.startswith(known + "-"):
            return known
    return name


def price_claude(usage, model, speed, geo):
    """USD for one request, or None if the model is not in the table.

    Returning None rather than 0 keeps an unpriced model visible instead of
    quietly deflating the total.
    """
    table = FAST_PRICES if speed == "fast" else PRICES
    rates = table.get(model) or PRICES.get(model)
    if not rates:
        return None
    base_in, write_5m, write_1h, read, out = rates
    creation = usage.get("cache_creation") or {}
    usd = (
        usage.get("input_tokens", 0) * base_in
        + creation.get("ephemeral_5m_input_tokens", 0) * write_5m
        + creation.get("ephemeral_1h_input_tokens", 0) * write_1h
        + usage.get("cache_read_input_tokens", 0) * read
        + usage.get("output_tokens", 0) * out
    ) / 1_000_000
    usd += ((usage.get("server_tool_use") or {}).get("web_search_requests", 0)
            * WEB_SEARCH_USD)
    if geo == "us":
        usd *= INFERENCE_GEO_US_MULTIPLIER
    return usd


def claude_rows(project_dir, only_cwd):
    """One row per billed request across this project's Claude Code logs."""
    slug = "-" + str(project_dir).lstrip("/").replace("/", "-")
    root = pathlib.Path(os.path.expanduser("~/.claude/projects"))
    dirs = sorted(root.glob("*")) if not only_cwd else [root / slug]
    seen_requests = set()
    for d in dirs:
        for path in sorted(glob.glob(str(d / "*.jsonl"))):
            for line in open(path, errors="replace"):
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                usage = (rec.get("message") or {}).get("usage")
                if not usage or rec.get("type") != "assistant":
                    continue
                # A retried or resumed request re-appears with the same id; the
                # API billed it once.
                request_id = rec.get("requestId")
                key = request_id or f"{rec.get('sessionId')}:{rec.get('uuid')}"
                if key in seen_requests:
                    continue
                seen_requests.add(key)
                model = normalize_model((rec.get("message") or {}).get("model"))
                speed = usage.get("speed")
                creation = usage.get("cache_creation") or {}
                yield {
                    "source": "claude-code",
                    "ts": rec.get("timestamp"),
                    "cwd": rec.get("cwd"),
                    "session": rec.get("sessionId"),
                    "key": key,
                    "model": model,
                    "speed": speed,
                    "service_tier": usage.get("service_tier"),
                    "input": usage.get("input_tokens", 0),
                    "output": usage.get("output_tokens", 0),
                    "cache_read": usage.get("cache_read_input_tokens", 0),
                    "cache_write_5m": creation.get("ephemeral_5m_input_tokens", 0),
                    "cache_write_1h": creation.get("ephemeral_1h_input_tokens", 0),
                    "web_searches": (usage.get("server_tool_use") or {})
                                    .get("web_search_requests", 0),
                    "usd": price_claude(usage, model, speed,
                                        usage.get("inference_geo")),
                }


def opencode_rows(project_dir, only_cwd):
    """One row per assistant message from opencode's sqlite store."""
    db = os.path.expanduser("~/.local/share/opencode/opencode.db")
    if not os.path.exists(db):
        return
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    sql = ("SELECT m.id, m.session_id, m.time_created, m.data, s.directory "
           "FROM message m JOIN session s ON s.id = m.session_id")
    params = ()
    if only_cwd:
        sql += " WHERE s.directory = ?"
        params = (str(project_dir),)
    for msg_id, session_id, created, data, directory in con.execute(sql, params):
        try:
            rec = json.loads(data)
        except json.JSONDecodeError:
            continue
        if rec.get("role") != "assistant":
            continue
        tokens = rec.get("tokens") or {}
        cache = tokens.get("cache") or {}
        # opencode reports its own cost. It is 0 for the subscription-hosted
        # models, which is accurate rather than missing — those tokens really
        # are not invoiced per-request — so it is stored as reported.
        yield {
            "source": "opencode",
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                time.gmtime((created or 0) / 1000)),
            "cwd": (rec.get("path") or {}).get("cwd") or directory,
            "session": session_id,
            "key": msg_id,
            "model": rec.get("modelID"),
            "provider": rec.get("providerID"),
            "input": tokens.get("input", 0),
            "output": tokens.get("output", 0),
            "reasoning": tokens.get("reasoning", 0),
            "cache_read": cache.get("read", 0),
            "cache_write": cache.get("write", 0),
            "usd": rec.get("cost"),
        }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=str(ROOT),
                    help="repo whose sessions to record (default: this one)")
    ap.add_argument("--all-projects", action="store_true",
                    help="every project, not just this repo")
    args = ap.parse_args()

    out_dir = OUT / "sessions"
    out_dir.mkdir(parents=True, exist_ok=True)
    seen = set()
    for path in out_dir.glob("*.jsonl"):
        for line in path.open():
            try:
                seen.add(json.loads(line)["key"])
            except (json.JSONDecodeError, KeyError):
                continue

    only_cwd = not args.all_projects
    buckets, counts, unpriced = {}, {}, set()
    for row in list(claude_rows(args.project, only_cwd)) + \
               list(opencode_rows(args.project, only_cwd)):
        if row["key"] in seen or not row.get("ts"):
            continue
        seen.add(row["key"])
        if row.get("usd") is None:
            unpriced.add(row.get("model"))
        buckets.setdefault(row["ts"][:7], []).append(row)
        counts[row["source"]] = counts.get(row["source"], 0) + 1

    total = 0
    for month, rows in buckets.items():
        with (out_dir / f"{month}.jsonl").open("a") as fh:
            for row in rows:
                fh.write(json.dumps(row, separators=(",", ":")) + "\n")
            total += len(rows)
    print(f"+{total} session rows " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    if unpriced:
        print(f"  unpriced models (usd=null): {', '.join(sorted(map(str, unpriced)))}",
              file=sys.stderr)


if __name__ == "__main__":
    main()
