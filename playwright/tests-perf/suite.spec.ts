/*
 * Deterministic suite for the benchmark's "Test run" column.
 *
 * The column used to be timed off tests/example.spec.ts, which navigates to
 * https://playwright.dev/ — so it measured DNS, RTT and someone else's CDN, and
 * came out at 3-14s with no usable signal. Worse, playwright.config.ts sets
 * retries:2 and trace:'on-first-retry', so one flaky external navigation both
 * tripled that test and switched tracing on for the retries.
 *
 * example.spec.ts is deliberately left alone: test-and-publish runs it as a
 * functional smoke, where reaching the real internet from inside the image is
 * the point. This file exists so the *timing* has its own workload.
 *
 * Principles taken from playwright/bench/runtime-probe.cjs, which already solved
 * this for the runtime probe:
 *   - no network at all. setContent rather than a local HTTP server, because
 *     these run in dind/dood containers where binding a port is one more thing
 *     that can differ between scenarios.
 *   - drop a warmup iteration: the first pays JIT warmup, lazy font/GPU init and
 *     first-touch page faults, none of which belong in a regression signal.
 *   - fixed iteration counts, never a time-boxed loop, so the work is identical
 *     on a fast and a slow runner and only the duration moves.
 *
 * Sized for ~4-5s per browser project on a GHA runner: comfortably above the
 * ~1s fixed cost of launching and closing a context, so the browser's own work
 * dominates. Raise ITERATIONS if that fixed cost ever grows.
 */
import { test, expect } from '@playwright/test';

const ITERATIONS = 6;      // + 1 warmup, dropped
const PAD_NODES = 800;     // layout weight — a trivial page hides layout regressions
const BUTTONS = 40;        // sized to fit the viewport so clicks never pay for scrolling

function fixture(): string {
  const pad = Array.from(
    { length: PAD_NODES },
    (_, i) => `<p class="pad">filler paragraph ${i} with enough text to force layout work</p>`,
  ).join('');
  const buttons = Array.from(
    { length: BUTTONS },
    (_, i) => `<button id="b${i}" data-n="0">button ${i}</button>`,
  ).join('');
  return `<!doctype html><meta charset="utf-8">
    <style>
      .pad { margin: 2px; font-size: 13px; }
      button { display: inline-block; width: 90px; margin: 1px; }
    </style>
    <h1 id="title">perf fixture</h1>
    <div id="buttons">${buttons}</div>
    <div id="pad">${pad}</div>
    <script>
      document.getElementById('buttons').addEventListener('click', (e) => {
        const b = e.target.closest('button');
        if (!b) return;
        b.dataset.n = String(Number(b.dataset.n) + 1);
        // Force a synchronous layout read so a click costs real layout work
        // rather than only event dispatch.
        document.getElementById('pad').getBoundingClientRect();
      });
    </script>`;
}

test('deterministic local workload', async ({ page }) => {
  // Generous but finite: the whole point is that the work is fixed, so a browser
  // slow enough to approach this should fail the bench rather than skew it.
  test.setTimeout(180_000);

  const html = fixture();

  for (let iteration = 0; iteration <= ITERATIONS; iteration++) {
    await page.setContent(html);

    // Layout + query: resolving many locators exercises the same DOM/layout
    // paths that regressed 9.3x when DCHECKs were compiled in.
    await expect(page.locator('#title')).toHaveText('perf fixture');
    expect(await page.locator('p.pad').count()).toBe(PAD_NODES);

    // Clicks: each one dispatches an event AND forces a layout read.
    for (let b = 0; b < BUTTONS; b++)
      await page.locator(`#b${b}`).click();

    // Non-vacuity: if the handler never ran, the clicks measured nothing.
    expect(await page.locator('#b0').getAttribute('data-n')).toBe('1');

    // Serialization + paint.
    const shot = await page.screenshot();
    expect(shot.length).toBeGreaterThan(1000);
  }
});
