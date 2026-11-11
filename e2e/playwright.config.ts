import { defineConfig, devices } from '@playwright/test';
import { APP, AUTH_FILE, chromePath, localKeys } from './env.ts';

const desktop = { viewport: { width: 1280, height: 800 } };
const mobile = { ...devices['Pixel 7'] };
const executablePath = chromePath();
const keys = localKeys();
// npm run e2e runs two phases; each keeps its own results.
const phase = process.env.E2E_PHASE ? `-${process.env.E2E_PHASE}` : '';

export default defineConfig({
  testDir: './tests',
  outputDir: `./results/artifacts${phase}`,
  // The tests share one database, so they run one at a time (npm run e2e runs the read only
  // page tests four at a time).
  workers: 1,
  fullyParallel: false,
  timeout: 120_000,
  expect: { timeout: 10_000 },
  retries: process.env.CI ? 1 : 0,
  reporter: [
    ['list'],
    ['json', { outputFile: `results/results${phase}.json` }],
    ['html', { open: 'never', outputFolder: `results/html${phase}` }],
  ],
  globalSetup: './global-setup.ts',
  use: {
    baseURL: APP,
    storageState: AUTH_FILE,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    launchOptions: executablePath ? { executablePath } : {},
  },
  projects: [
    { name: 'desktop-light', testMatch: /pages\.spec/, use: { ...desktop, colorScheme: 'light' } },
    { name: 'desktop-dark', testMatch: /pages\.spec/, use: { ...desktop, colorScheme: 'dark' } },
    { name: 'mobile-light', testMatch: /pages\.spec/, use: { ...mobile, colorScheme: 'light' } },
    { name: 'mobile-dark', testMatch: /pages\.spec/, use: { ...mobile, colorScheme: 'dark' } },
    { name: 'crawl-desktop', testMatch: /crawl\.spec/, use: { ...desktop, colorScheme: 'light' } },
    { name: 'crawl-mobile', testMatch: /crawl\.spec/, use: { ...mobile, colorScheme: 'dark' } },
    { name: 'scenarios', testMatch: /scenarios\.spec/, use: { ...desktop, colorScheme: 'light' } },
  ],
  webServer: {
    command:
      'node ../node_modules/vite/bin/vite.js ../app --config ../app/vite.config.ts --port 5173 --strictPort',
    url: APP,
    reuseExistingServer: true,
    timeout: 120_000,
    env: {
      VITE_SUPABASE_URL: keys.api,
      VITE_SUPABASE_PUBLISHABLE_KEY: keys.publishable,
      VITE_ALLOWED_EMAIL_DOMAIN: 'example.com',
      VITE_ENABLE_DEV_LOGIN: 'false',
    },
  },
});
