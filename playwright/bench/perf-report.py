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
import sys

CONTROL = "official"
# A ratio this far above the control is worth a look. Deliberately loose: musl
# builds are not expected to match glibc byte for byte, and the failure mode we
# care about (a build-flag regression) showed up at 7x-9x, not 1.4x.
RATIO_WARN = 1.30
# Relative move of a ratio between two runs. Both runs divide out their own
# runner, so this survives runner noise far better than a raw millisecond delta.
DRIFT_WARN = 0.20


def load(directory):
    """{browser: {target: {metric: median_ms}}} from every <target>-<browser>.json."""
    out = {}
    for path in sorted(pathlib.Path(directory).rglob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"skipping unparsable {path}", file=sys.stderr)
            continue
        if "metrics" not in doc or "browser" not in doc or "target" not in doc:
            continue
        per_target = out.setdefault(doc["browser"], {})
        per_target[doc["target"]] = {
            "meta": doc,
            "metrics": {k: v["median_ms"] for k, v in doc["metrics"].items()},
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


def render(current, previous):
    lines = ["## Runtime perf probe", ""]
    lines += [
        "Browser execution speed of the images this run built, against the official",
        "MCR image probed on a sibling runner. **Observe-only** — nothing here gates a",
        "merge. Read the `×off` columns, not the milliseconds: absolute times swing",
        f"20-30% between hosted runners. `⚠` marks a ratio above {RATIO_WARN:.2f}x;",
        f"`🔺`/`🔻` mark a ratio that moved more than {DRIFT_WARN:.0%} since the previous",
        "successful run on `main`.",
        "",
    ]

    for browser in sorted(current):
        data = current[browser]
        lines += [f"### {browser}", ""]

        control = data.get(CONTROL)
        if not control:
            lines += [
                f"No `{CONTROL}` control cell for {browser} — ratios unavailable, "
                "raw medians below.",
                "",
            ]

        targets = [t for t in sorted(data) if t != CONTROL]
        now = ratios(data)
        before = ratios(previous.get(browser, {})) if previous else {}

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

    lines += _footer(current)
    return "\n".join(lines) + "\n"


def _footer(current):
    runners = sorted(
        {
            d["meta"]["runner"]["cpu"]
            for data in current.values()
            for d in data.values()
        }
    )
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
        "| `locator_click` | 200 `locator.click()` calls. The dominant real cost: injected query + visible/stable/enabled polling, each re-paying layout. |",
        "| `screenshot` | 10 full-page PNGs. CI configs capture these on failure and on retry. |",
        "| `layout` | 2000 forced synchronous reflows in-page. The DCHECK canary — this was 9.3x on the accidental debug build. |",
        "| `dom_churn` | 20000 create/append/remove in-page. Was 7.2x on the same build. |",
        "| `js_alloc` | 2M short-lived object allocations in-page. |",
        "| `int_math` | 30M integer ops (`Math.imul` + `\\|0`) in-page. No libm call — that is the point. |",
        "| `libm_fmod` | 3M `%` on doubles past 2^53, i.e. `fmod()`. Isolated because musl's fmod is ~2.1x glibc's and it used to contaminate the JIT number. |",
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
