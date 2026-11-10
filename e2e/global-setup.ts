// Signs in once with the test account and saves the session for every test.
// The data itself is loaded before the run by `npm run e2e` (Sandbox starting data plus a few
// confirmed and asked class weeks), so every run starts from the same place.
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { chromium, type FullConfig } from '@playwright/test';
import { APP, AUTH_FILE, EMAIL, chromePath, signInLink } from './env.ts';
import { requireWrapper } from './tests/fixtures.ts';

export default async function globalSetup(_config: FullConfig) {
  requireWrapper();
  mkdirSync(dirname(AUTH_FILE), { recursive: true });
  const executablePath = chromePath();
  const browser = await chromium.launch(executablePath ? { executablePath } : {});
  const page = await browser.newPage();
  await page.goto(await signInLink(EMAIL));
  await page.waitForURL((u) => u.toString().startsWith(APP) && !u.hash.includes('access_token'), {
    timeout: 30_000,
  });
  await page.getByRole('navigation').first().waitFor({ timeout: 30_000 });
  await page.context().storageState({ path: AUTH_FILE });
  await browser.close();
}
