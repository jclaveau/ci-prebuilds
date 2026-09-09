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
                       [--short-models | --short-browsers | --slot-filters]
"""

import argparse
import collections
import json
import math
import pathlib
import sys

# How often each model turned up across this repo's probe runs. Only used to
# size the slot allocation below, so a stale rate costs a round, not a wrong
# answer.
FLEET_RATES = {"7763": 0.50, "9V74": 0.25, "8573C": 0.10,
               "8370C": 0.10, "6973P-C": 0.05}
UNKNOWN_RATE = 0.10


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


def slot_filters(short, models, slots, rates):
    """Per-slot `want_cpus`, as perf-probe spells it: ';' between slots.

    A slot is a job, and a job is one draw. GitHub cancels runs rather than
    jobs, so a draw of a model that already met its quota cannot be killed once
    it starts — it has to be refused before it begins, which means deciding at
    dispatch which slot may accept what.

    Pinning each slot to one model would trade runner-minutes for rounds: a slot
    reserved for a 10%-of-fleet model rejects the 50% draw the campaign also
    still needed. So the cap is per model instead — at most `need / rate` slots
    may accept it, which is the number whose expected yield is the need itself.
    Rare models end up on every slot and common ones on the first few, and the
    surplus that used to run a full probe becomes a 20-second refusal.
    """
    caps = {}
    for model in models:
        need = max((n for (_, m), n in short.items() if m == model), default=0)
        if need:
            rate = rates.get(model, UNKNOWN_RATE)
            caps[model] = min(slots, max(1, math.ceil(need / rate)))
    if not caps:
        return ""
    used = max(caps.values())
    return ";".join(
        ",".join(m for m, cap in caps.items() if slot <= cap)
        for slot in range(1, used + 1)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("state")
    parser.add_argument("--models", required=True)
    parser.add_argument("--browsers", required=True)
    parser.add_argument("--target", type=int, required=True)
    parser.add_argument("--short-models", action="store_true")
    parser.add_argument("--short-browsers", action="store_true")
    parser.add_argument("--slot-filters", action="store_true")
    parser.add_argument("--slots", type=int, default=6,
                        help="most jobs one dispatch may spend per browser")
    args = parser.parse_args()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    browsers = [b.strip() for b in args.browsers.split(",") if b.strip()]
    counts = draws(pathlib.Path(args.state), models)

    short = {
        (browser, model): args.target - counts.get((browser, model), 0)
        for browser in browsers
        for model in models
        if counts.get((browser, model), 0) < args.target
    }

    if args.short_models:
        print(",".join(m for m in models if any(m == key[1] for key in short)))
        return 0
    if args.short_browsers:
        print(",".join(b for b in browsers if any(b == key[0] for key in short)))
        return 0
    if args.slot_filters:
        print(slot_filters(short, models, args.slots, FLEET_RATES))
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
