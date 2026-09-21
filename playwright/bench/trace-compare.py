#!/usr/bin/env python3
"""Per-scenario, per-event self-time SHARES ours/official from trace-probe.cjs outputs.

  python3 trace-compare.py <dir with <arm>-trace.json files> [--md]

Every `<arm>-trace.json` but `official-trace.json` is compared against it.
The share (self ms / scenario wall) is the column to read: on a noisy box the
wall ratio swings 20% with arm order while the shares hold within 0.85-1.2,
and a build that lost one subsystem shows one share doubled while a uniform
slowdown moves none of them.
"""
import json
import pathlib
import sys

CONTROL = "official"


def rows(ours, official):
    wall_o, wall_c = ours["wall_ms"], official["wall_ms"]
    names = set(ours["self_ms"]) | set(official["self_ms"])
    floor = max(8, 0.01 * max(wall_o, wall_c))
    out = []
    for n in names:
        so, sc = ours["self_ms"].get(n, 0), official["self_ms"].get(n, 0)
        if max(so, sc) < floor:
            continue
        share_o, share_c = 100 * so / wall_o, 100 * sc / wall_c
        out.append((n, so, sc, share_o, share_c, share_o / share_c if sc else float("inf")))
    out.sort(key=lambda r: -max(r[3], r[4]))
    return out[:14]


def pipeline_rows(ours, official):
    """thread|event rows with ms/iter and n/iter per arm, hottest first."""
    a, o = ours["by_thread"], official["by_thread"]
    ia, io = max(ours["iters"], 1), max(official["iters"], 1)
    keys = set(a) | set(o)
    out = []
    for k in keys:
        ra, ro = a.get(k, {"ms": 0, "n": 0}), o.get(k, {"ms": 0, "n": 0})
        ms_a, ms_o = ra["ms"] / ia, ro["ms"] / io
        if max(ms_a, ms_o) < 0.2:
            continue
        out.append((k, ms_a, ra["n"] / ia, ms_o, ro["n"] / io,
                    ms_a / ms_o if ms_o else float("inf")))
    out.sort(key=lambda r: -max(r[1], r[3]))
    return out[:24]


def render_pipeline(arm, ours, official, md):
    """The compositor side: per thread and event, ms and COUNT per iteration.

    A count that differs is a different pipeline shape (more or fewer raster
    tasks, tiles, frames per navigation), which no per-event ms ratio shows.
    """
    for sc in ours.get("pipeline", {}):
        if sc not in official.get("pipeline", {}):
            continue
        a, o = ours["pipeline"][sc], official["pipeline"][sc]
        table = pipeline_rows(a, o)
        if not table:
            continue
        if md:
            print(f"\n**{arm}** `{sc}` compositor pipeline, per iteration "
                  f"(wall {a['wall_ms'] / a['iters']:.1f} / {o['wall_ms'] / o['iters']:.1f} ms)\n")
            print("| thread / event | ours ms | ours n | official ms | official n | ms× |")
            print("|---|---:|---:|---:|---:|---:|")
            for k, ms_a, n_a, ms_o, n_o, r in table:
                print(f"| `{k[:60]}` | {ms_a:.2f} | {n_a:.1f} | {ms_o:.2f} | {n_o:.1f} | {r:.2f} |")
        else:
            print(f"== {arm} {sc} pipeline (wall/iter {a['wall_ms'] / a['iters']:.1f} / {o['wall_ms'] / o['iters']:.1f} ms)")
            for k, ms_a, n_a, ms_o, n_o, r in table:
                print(f"   {k[:60]:<60}{ms_a:>8.2f}{n_a:>6.1f}{ms_o:>8.2f}{n_o:>6.1f}{r:>7.2f}")


def render(arm, ours, official, md):
    for sc in ours["scenarios"]:
        a, o = ours["scenarios"][sc], official["scenarios"][sc]
        head = (f"{sc}: wall {a['wall_ms']:.0f} / {o['wall_ms']:.0f} ms"
                f" = {a['wall_ms'] / o['wall_ms']:.2f}, events {a['events']} / {o['events']}")
        table = rows(a, o)
        if md:
            print(f"\n**{arm}** {head}\n")
            print("| event (self) | ours ms | official ms | ours % | official % | share× |")
            print("|---|---:|---:|---:|---:|---:|")
            for n, so, sc_, po, pc, r in table:
                print(f"| `{n[:48]}` | {so:.0f} | {sc_:.0f} | {po:.1f} | {pc:.1f} | {r:.2f} |")
        else:
            print(f"== {arm} {head}")
            print(f"   {'event (self)':<48}{'ours ms':>8}{'off ms':>8}{'ours %':>8}{'off %':>7}{'share':>7}")
            for n, so, sc_, po, pc, r in table:
                print(f"   {n[:48]:<48}{so:>8.0f}{sc_:>8.0f}{po:>8.1f}{pc:>7.1f}{r:>7.2f}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    md = "--md" in sys.argv
    directory = pathlib.Path(args[0] if args else ".")
    control = directory / f"{CONTROL}-trace.json"
    if not control.exists():
        print(f"no {control}", file=sys.stderr)
        return 1
    official = json.loads(control.read_text())
    arms = sorted(p for p in directory.glob("*-trace.json") if p != control)
    if not arms:
        print(f"no ours arm beside {control}", file=sys.stderr)
        return 1
    for path in arms:
        ours = json.loads(path.read_text())
        arm = path.name[: -len("-trace.json")]
        render(arm, ours, official, md)
        render_pipeline(arm, ours, official, md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
