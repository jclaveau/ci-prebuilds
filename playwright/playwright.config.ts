import { defineConfig, devices } from '@playwright/test';

/**
 * Read environment variables from file.
 * https://github.com/motdotla/dotenv
 */
// import dotenv from 'dotenv';
// import path from 'path';
// dotenv.config({ path: path.resolve(__dirname, '.env') });

/**
 * See https://playwright.dev/docs/test-configuration.
 */

// Both flavors stage all three musl/glibc browsers at PW SDK's auto-discovery
// cache path (PLAYWRIGHT_BROWSERS_PATH=/ms-playwright) — on Alpine the
// alpine-...-playwright Dockerfile COPYs musl-native chromium-headless-shell +
// patched Firefox + WebKit-WPE from the `playwright-alpine-browsers` producer
// image; on the standard flavor PW's own glibc browsers apply. No
// executablePath override needed on either. Same project list everywhere.
// `-perf` twins of each browser, pointed at tests-perf/ and used ONLY by the
// benchmark's timed step. They exist because the timing has to be deterministic
// while tests/example.spec.ts deliberately is not — it navigates to the real
// playwright.dev as test-and-publish's functional smoke.
//
// Opt-in via PW_PERF_PROJECTS so `playwright test` with no --project keeps doing
// exactly what it did before: test-and-publish invokes it that way and would
// otherwise silently start running the perf workload as part of its smoke.
//
// retries:0 + trace:'off' override the CI defaults below on purpose. With
// retries:2 one flaky iteration tripled the measured time, and
// trace:'on-first-retry' then added tracing overhead on top — so a retry made the
// number both wrong and wrong in the direction that looks like a real
// regression. Here a failure should fail, not quietly become a slow pass.
const perfProject = (name: string, device: keyof typeof devices) => ({
  name: `${name}-perf`,
  testDir: './tests-perf',
  retries: 0,
  use: { ...devices[device], trace: 'off' as const },
});

const perfProjects = process.env.PW_PERF_PROJECTS
  ? [
      perfProject('chromium', 'Desktop Chrome'),
      perfProject('firefox', 'Desktop Firefox'),
      perfProject('webkit', 'Desktop Safari'),
    ]
  : [];

const projects = [
  { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
  { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ...perfProjects,

  /* Test against mobile viewports. */
  // {
  //   name: 'Mobile Chrome',
  //   use: { ...devices['Pixel 5'] },
  // },
  // {
  //   name: 'Mobile Safari',
  //   use: { ...devices['iPhone 12'] },
  // },

  /* Test against branded browsers. */
  // {
  //   name: 'Microsoft Edge',
  //   use: { ...devices['Desktop Edge'], channel: 'msedge' },
  // },
  // {
  //   name: 'Google Chrome',
  //   use: { ...devices['Desktop Chrome'], channel: 'chrome' },
  // },
];

export default defineConfig({
  testDir: './tests',
  /* Run tests in files in parallel */
  fullyParallel: true,
  /* Fail the build on CI if you accidentally left test.only in the source code. */
  forbidOnly: !!process.env.CI,
  /* Retry on CI only */
  retries: process.env.CI ? 2 : 0,
  /* Opt out of parallel tests on CI. */
  workers: process.env.CI ? 1 : undefined,
  /* Reporter to use. See https://playwright.dev/docs/test-reporters */
  reporter: 'html',
  /* Shared settings for all the projects below. See https://playwright.dev/docs/api/class-testoptions. */
  use: {
    /* Base URL to use in actions like `await page.goto('')`. */
    // baseURL: 'http://localhost:3000',

    /* Collect trace when retrying the failed test. See https://playwright.dev/docs/trace-viewer */
    trace: 'on-first-retry',
  },

  /* Configure projects for major browsers — chromium + firefox + webkit on
     every flavor. See `projects` block above for rationale. */
  projects,

  /* Run your local dev server before starting the tests */
  // webServer: {
  //   command: 'npm run start',
  //   url: 'http://localhost:3000',
  //   reuseExistingServer: !process.env.CI,
  // },
});
