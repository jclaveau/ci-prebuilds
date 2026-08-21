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
//
// PW_WEBKIT_UNSUPPORTED drops the webkit project. Playwright 1.62.1 sends
// `Page.overrideSetting: PushAPIEnabled` on every newPage and no WebKit we
// have published understands it, so on Alpine — which stages OUR build — the
// two webkit tests fail while chromium and firefox pass. The standard flavor
// runs Playwright's own glibc WebKit and is unaffected, which is why this is
// an env gate on the alpine legs rather than a line deleted from the list.
// Delete the gate once a wk-<rev> built from PW_WEBKIT_PATCHES_REF ships:
// https://github.com/jclaveau/ci-prebuilds/issues/100
const projects = [
  { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
  { name: 'webkit', use: { ...devices['Desktop Safari'] } },

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
].filter((project) => !(
  process.env.PW_WEBKIT_UNSUPPORTED === '1' && project.name === 'webkit'
));

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
