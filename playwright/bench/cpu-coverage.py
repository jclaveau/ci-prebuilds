#!/usr/bin/env python3
"""Tally how many probe DRAWS each (browser, CPU model) pair has so far.

A draw is one perf-probe job: one machine, every arm measured on it. The
alpine/official ratio is not portable across silicon — chromium's `layout` and
`screenshot` trade places between an EPYC 9V74 and an EPYC 7763 — so a claim
about a row needs draws on several models, and this says which are still short.

The runner model cannot be requested, only drawn, so the models are given as
substrings to match against `runner.cpu` and coverage is filled by repeated
dispatch. Everything under <state-dir> counts, one subdirectory per draw, which
is how `sample-cpu-models.sh` accumulates rounds.

usage: cpu-coverage.py <state-dir> --models CSV --browsers CSV --target N
                       [--short-models | --short-browsers]
"""

import argparse
import collections
import json
import pathlib
import sys


def draws(root, models):
    """{(browser, model): number of distinct draw directories}."""
    seen = collections.defaultdict(set)
    for path in sorted(root.rglob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        cpu = (doc.get("runner") or {}).get("cpu")
        browser = doc.get("browser")
        if not cpu or not browser:
            continue
        model = next((m for m in models if m in cpu), None)
        if model is None:
            continue
        seen[(browser, model)].add(str(path.parent))
    return {key: len(dirs) for key, dirs in seen.items()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("state")
    parser.add_argument("--models", required=True)
    parser.add_argument("--browsers", required=True)
    parser.add_argument("--target", type=int, required=True)
    parser.add_argument("--short-models", action="store_true")
    parser.add_argument("--short-browsers", action="store_true")
    args = parser.parse_args()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    browsers = [b.strip() for b in args.browsers.split(",") if b.strip()]
    counts = draws(pathlib.Path(args.state), models)

    short = {
        (browser, model)
        for browser in browsers
        for model in models
        if counts.get((browser, model), 0) < args.target
    }

    if args.short_models:
        print(",".join(m for m in models if any(m == s[1] for s in short)))
        return 0
    if args.short_browsers:
        print(",".join(b for b in browsers if any(b == s[0] for s in short)))
        return 0

    width = max([len(b) for b in browsers] + [8])
    print(f"{'':<{width}}  " + "  ".join(f"{m:>10}" for m in models))
    for browser in browsers:
        cells = []
        for model in models:
            got = counts.get((browser, model), 0)
            cells.append(f"{got}/{args.target}" + ("" if got >= args.target else " *"))
        print(f"{browser:<{width}}  " + "  ".join(f"{c:>10}" for c in cells))
    print(f"\n{len(short)} of {len(browsers) * len(models)} cells still short (*)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
