#!/usr/bin/env python3
"""Fail unless every arm of a browser was measured on ONE machine.

The alpine/official ratio is runner-dependent — the same webkit reads
`libm_fmod` 5.35 on an EPYC 7763, 6.3 on a 9V74 and 7.65 on a Xeon 8370C, at a
within-class CV of 0.5%. perf-probe.yml therefore runs every arm of a browser
inside a single job, which puts them on one machine by construction.

"By construction" is exactly the kind of claim that quietly stops being true,
so this asserts it from the artifacts instead: each run records `runner.cpu`,
and a browser whose runs disagree is not a comparison. Browsers run in separate
jobs and legitimately land on different models, so the check is per-browser.

usage: assert-one-machine.py <dir-of-probe-json>
"""

import collections
import glob
import json
import os
import sys


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "perf-current"
    cpus: dict[str, set[str]] = collections.defaultdict(set)
    for path in glob.glob(os.path.join(root, "*.json")):
        with open(path) as fh:
            doc = json.load(fh)
        cpu = (doc.get("runner") or {}).get("cpu")
        browser = doc.get("browser")
        if cpu and browser:
            cpus[browser].add(cpu)

    if not cpus:
        print(f"::error::no probe JSON with a runner.cpu under {root}")
        return 1

    bad = 0
    for browser, models in sorted(cpus.items()):
        if len(models) > 1:
            print(f"::error::{browser} was measured across {len(models)} CPU "
                  f"models, so its arms are not comparable: "
                  f"{', '.join(sorted(models))}")
            bad = 1
        else:
            print(f"ok: {browser} on {next(iter(models))}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
