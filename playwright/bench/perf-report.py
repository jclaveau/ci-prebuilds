#!/usr/bin/env python3
"""Turn the per-cell runtime-probe JSONs into a markdown report.

The only trustworthy number here is the RATIO of each of our images against the
`official` MCR control probed in the same workflow run: hosted runners vary by
20-30% between jobs, so absolute milliseconds move on their own. Ratios are also
what makes a delta against a previous run meaningful, since both runs divide out
their own runner.

Usage: perf-report.py <current-dir> [<previous-dir>]
"""

import json
import pathlib
import statistics
import sys

CONTROL = "official"
# A ratio this far above the control is worth a look. Deliberately loose: musl
# builds are not expected to match glibc byte for byte, and the failure mode we
# care about (a build-flag regression) showed up at 7x-9x, not 1.4x.
RATIO_WARN = 1.30
# Relative move of a ratio between two runs. Both runs divide out their own
# runner, so this survives runner noise far better than a raw millisecond delta.
DRIFT_WARN = 0.20
# How far our arm's cross-model scaling may part from the control's before the
# row is called CPU-sensitive. Both arms slow down on a slower machine; only one
# of them doing so is a property of the build, not of the silicon.
SENSITIVITY_WARN = 0.10


def load(directory):
    """{(browser, cpu): {target: {metric: median_ms}}} from every probe JSON.

    A (browser, target) pair may be measured more than once — `runs` re-runs the
    whole probe container, which is the only way to average out the noise that
    lives between container starts rather than inside one browser session. Each
    repetition lands in its own file, and this medians across them.

    Keying straight into a dict here would have let the last file win silently,
    reporting one draw while the run had paid for several.

    The runner CPU model is part of the key, not decoration. A run can now fan
    out several independent draws per browser, and the alpine/official ratio
    itself moves with the silicon — chromium's `layout` and `screenshot` swap
    which one is worse between EPYC 9V74 and EPYC 7763. Medianing across models
    would average two different populations into a number describing neither.
    Both arms of a draw share a job, hence a machine, so this key never splits a
    pair.
    """
    collected = {}
    metas = {}
    for path in sorted(pathlib.Path(directory).rglob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"skipping unparsable {path}", file=sys.stderr)
            continue
        if "metrics" not in doc or "browser" not in doc or "target" not in doc:
            continue
        cpu = doc.get("runner", {}).get("cpu") or "unknown CPU"
        key = (doc["browser"], cpu, doc["target"])
        metas.setdefault(key, doc)
        for metric, value in doc["metrics"].items():
            collected.setdefault(key, {}).setdefault(metric, []).append(
                value["median_ms"]
            )
    out = {}
    for (browser, cpu, target), per_metric in collected.items():
        out.setdefault((browser, cpu), {})[target] = {
            "meta": metas[(browser, cpu, target)],
            "runs": max(len(v) for v in per_metric.values()),
            "metrics": {k: statistics.median(v) for k, v in per_metric.items()},
        }
    return out


def ratios(browser_data):
    """{target: {metric: ratio-vs-control}} — empty when the control is missing."""
    control = browser_data.get(CONTROL)
    if not control:
        return {}
    out = {}
    for target, data in browser_data.items():
        if target == CONTROL:
            continue
        out[target] = {
            metric: value / control["metrics"][metric]
            for metric, value in data["metrics"].items()
            if control["metrics"].get(metric)
        }
    return out


def sensitivity(current):
    """Per arm, how each row scales from one CPU model to another.

    The ×off ratio divides the runner out, which is what makes it comparable —
    and also what hides WHICH arm moved when the ratio changes between models.
    chromium's `layout` reads 1.61 on an EPYC 7763 and 1.27 on a 9V74, and only
    the raw medians say that the control is flat across the two (0.97) while
    ours is not (0.77). One is a fact about our build; the ratio alone cannot
    tell them apart.

    Both arms of a draw share a machine, so their ms are directly comparable
    within a model; across models they are not, which is exactly the quantity
    measured here.
    """
    by_browser = {}
    for (browser, cpu), data in current.items():
        by_browser.setdefault(browser, {})[cpu] = data

    lines = []
    for browser, models in sorted(by_browser.items()):
        if len(models) < 2:
            continue
        base, *others = sorted(models)
        lines += [f"### {browser} — CPU-model sensitivity", "",
                  f"Each arm against its own median on `{base}`. `⚡` marks a row whose "
                  f"scaling parts between the two arms by more than "
                  f"{SENSITIVITY_WARN:.0%}: both slow down on a slower machine, and only "
                  "one of them doing so is a property of the build. One draw per model "
                  "can part on noise alone, so this is a pointer to check, not a "
                  "verdict — read the arm's own samples before believing it.", ""]
        targets = sorted(models[base])
        for model in others:
            lines += [f"**`{model}` ÷ `{base}`**", ""]
            lines.append("| metric | " + " | ".join(targets) + " |")
            lines.append("|" + "---|" * (len(targets) + 1))
            for metric in sorted(models[base].get(CONTROL, {}).get("metrics", {})):
                scaled = {}
                for target in targets:
                    was = models[base].get(target, {}).get("metrics", {}).get(metric)
                    now = models[model].get(target, {}).get("metrics", {}).get(metric)
                    scaled[target] = now / was if was and now else None
                ours = [v for t, v in scaled.items() if t != CONTROL and v]
                control = scaled.get(CONTROL)
                parted = (control and ours
                          and max(abs(v - control) for v in ours) > SENSITIVITY_WARN)
                cells = [f"{scaled[t]:.2f}" if scaled[t] else "—" for t in targets]
                lines.append(f"| `{metric}`{' ⚡' if parted else ''} | "
                             + " | ".join(cells) + " |")
            lines.append("")
    return lines


def render(current, previous):
    lines = ["## Runtime perf probe", ""]
    lines += [
        "Browser execution speed of the images this run built, against the official MCR",
        "image probed **on the same runner, in the same job** — hosted runners hand out",
        "different CPU models per job (EPYC 9V74, Xeon 8370C and Xeon 6973P-C all showed",
        "up in one run), so a control on a sibling runner is not a control. That holds",
        "for a SECOND image of ours too (`alpine-b`, from perf-probe's `image_b`): an",
        "arm and the shipped build share the machine here, rather than being differenced",
        "across two workflow runs. `assert-one-machine.py` checks it per draw instead",
        "of trusting the arrangement.",
        "**Observe-only** — nothing here gates a merge. Read the `×off` columns, not the",
        f"milliseconds. `⚠` marks a ratio above {RATIO_WARN:.2f}x;",
        f"`🔺`/`🔻` mark a ratio that moved more than {DRIFT_WARN:.0%} since the previous",
        "successful run on `main`.",
        "",
        "One section per browser **and CPU model**. A run can fan out several",
        "independent draws per browser, and the ratio does not carry across silicon —",
        "chromium's two worst rows, `layout` and `screenshot`, swap which one is worse",
        "between an EPYC 9V74 and an EPYC 7763. Averaging the models would produce a",
        "number describing neither. For the same reason `Δ×` only fills in when the",
        "previous run also drew that model.",
        "",
    ]

    for browser, cpu in sorted(current):
        data = current[(browser, cpu)]
        lines += [f"### {browser} — `{cpu}`", ""]

        control = data.get(CONTROL)
        if not control:
            lines += [
                f"No `{CONTROL}` control cell for {browser} — ratios unavailable, "
                "raw medians below.",
                "",
            ]

        targets = [t for t in sorted(data) if t != CONTROL]
        now = ratios(data)
        before = ratios(previous.get((browser, cpu), {})) if previous else {}

        header = ["metric"]
        if control:
            header.append(f"{CONTROL} (ms)")
        for target in targets:
            header += [f"{target} (ms)", "×off", "Δ×"]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "---|" * len(header))

        metrics = sorted({m for d in data.values() for m in d["metrics"]})
        for metric in metrics:
            row = [f"`{metric}`"]
            if control:
                base = control["metrics"].get(metric)
                row.append(f"{base:,.1f}" if base is not None else "—")
            for target in targets:
                value = data[target]["metrics"].get(metric)
                row.append(f"{value:,.1f}" if value is not None else "—")

                ratio = now.get(target, {}).get(metric)
                if ratio is None:
                    row += ["—", "—"]
                    continue
                row.append(f"{ratio:.2f}x" + (" ⚠" if ratio >= RATIO_WARN else ""))

                was = before.get(target, {}).get(metric)
                if was is None or not was:
                    row.append("—")
                else:
                    drift = ratio / was - 1
                    mark = "🔺" if drift >= DRIFT_WARN else ("🔻" if drift <= -DRIFT_WARN else "")
                    row.append(f"{drift:+.0%} {mark}".strip())
            lines.append("| " + " | ".join(row) + " |")

        versions = ", ".join(
            f"{t}: `{d['meta']['browser_version']}` ({d['meta']['libc']})"
            for t, d in sorted(data.items())
        )
        lines += ["", versions, ""]

    lines += sensitivity(current)
    lines += _footer(current)
    return "\n".join(lines) + "\n"


def _footer(current):
    runners = sorted({cpu for _, cpu in current})
    return [
        "<details><summary>What each metric measures</summary>",
        "",
        "| metric | measures |",
        "|---|---|",
        "| `launch` | `browserType.launch()` + `close()`. Paid per worker and after every crash. Moves on linker / fontconfig / dlopen regressions. |",
        "| `context_page` | `newContext` + `newPage` + close. Playwright's default is one context per test, so this scales with test count. |",
        "| `goto_cold` | Navigation in a fresh context: download, parse, compile, first paint. |",
        "| `goto_warm` | Same page again, everything cached: the navigation machinery alone. |",
        "| `eval_rtt` | 500 trivial `page.evaluate` round trips. Multiplied by every Playwright action. |",
        "| `locator_click` | 100 `locator.click()` calls with full actionability. Frame-cadence bound, so a healthy build pins to a whole number of frames (chromium 33.3ms/click = 2 frames at 60Hz) regardless of libc or CPU. It only moves when a build misses its frame budget. |",
        "| `click_force` | The same 100 clicks with `force`, which skips the visible/stable/enabled waiting. No frame quantization left: this is the injected query + hit test + event dispatch. |",
        "| `screenshot` | 10 viewport PNGs — Playwright's default, and what `screenshot: 'only-on-failure'` captures. On chromium and webkit the capture waits on a frame commit, so per-shot cost quantizes to whole 60Hz frames (50.0ms = 3) and the ratio steps between small integer quotients rather than moving continuously: 1.00 is both arms inside the same frame budget, 0.66 is two frames against three. Only firefox measures speed here. |",
        "| `layout` | 2000 forced synchronous reflows in-page. The DCHECK canary, and by far the most sensitive metric here: the accidental debug build measured 110x. |",
        "| `dom_churn` | 20000 create/append/remove in-page. 5.3x on the same build. |",
        "| `js_alloc` | 2M short-lived object allocations in-page. |",
        "| `int_math` | 30M integer ops (`Math.imul` + `\\|0`) in-page. No libm call — that is the point. |",
        "| `libm_fmod` | 9M `%` on doubles past 2^53. Named for a libm call that "
        "the engines mostly do NOT make — counted zero under JSC — so read it as the "
        "engine's own double-modulo path, per-engine, never as a libc verdict. |",
        "",
        "</details>",
        "",
        "Runner CPUs this run: " + ", ".join(f"`{r}`" for r in runners) + ".",
    ]


def main():
    current = load(sys.argv[1])
    previous = load(sys.argv[2]) if len(sys.argv) > 2 else {}
    if not current:
        print("No probe results found — every cell failed or was skipped.")
        return
    sys.stdout.write(render(current, previous))


if __name__ == "__main__":
    main()
