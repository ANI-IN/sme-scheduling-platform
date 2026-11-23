// Every test fails on a browser console error, an uncaught page error or a failed request.
import { test as base, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import pg from 'pg';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { DB_URL, ROOT } from '../env.ts';

export type Problems = {
  list: string[];
  /** Messages that are expected in this test (for example a rule refusing a click on purpose). */
  allow: RegExp[];
  /** Expected problems that were seen, kept for the report. */
  allowed: string[];
};

export const test = base.extend<{ problems: Problems }>({
  problems: [
    async ({ page }, use, testInfo) => {
      const p: Problems = { list: [], allow: [], allowed: [] };
      page.on('console', (m) => {
        if (m.type() === 'error') p.list.push(`console error: ${m.text()}`);
      });
      page.on('pageerror', (e) => p.list.push(`page error: ${e.message}`));
      page.on('requestfailed', (r) => {
        const why = r.failure()?.errorText ?? '';
        // Requests cancelled by a page change are not failures.
        if (/ERR_ABORTED|NS_BINDING_ABORTED/.test(why)) return;
        p.list.push(`request failed: ${r.method()} ${r.url()} ${why}`);
      });
      page.on('response', (r) => {
        if (r.status() >= 400)
          p.list.push(`HTTP ${r.status()}: ${r.request().method()} ${r.url()}`);
      });
      await use(p);
      const real: string[] = [];
      for (const x of p.list) (p.allow.some((a) => a.test(x)) ? p.allowed : real).push(x);
      if (p.allowed.length)
        testInfo.annotations.push({ type: 'expected refusals', description: p.allowed.join('\n') });
      expect(real, 'console errors and failed requests').toEqual([]);
    },
    { auto: true },
  ],
});
export { expect };

/** Wait until the page has loaded its data and no loading placeholders are left. */
export async function ready(page: Page) {
  await page.waitForLoadState('networkidle');
  // Pages load on first visit: wait for the page title, then for its data.
  if (!page.url().includes('/login'))
    await page
      .locator('main h1')
      .first()
      .waitFor({ timeout: 15_000 })
      .catch(() => {});
  await expect(page.locator('.animate-pulse')).toHaveCount(0, { timeout: 15_000 });
}

/** axe accessibility check: serious and critical problems fail the test. */
export async function a11y(page: Page, label: string, include?: string) {
  let b = new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  if (include) b = b.include(include);
  const r = await b.analyze();
  const bad = r.violations
    .filter((v) => v.impact === 'serious' || v.impact === 'critical')
    .map(
      (v) =>
        `${v.id} (${v.impact}): ${v.help}. ${v.nodes.length} place(s): ${v.nodes
          .slice(0, 4)
          .map((n) => n.target.join(' '))
          .join(' | ')}`,
    );
  expect.soft(bad, `accessibility of ${label}`).toEqual([]);
}

/** On a phone the page must never scroll sideways. */
export async function noSidewaysScroll(page: Page, label: string) {
  const over = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect.soft(over, `${label} scrolls sideways by ${over}px`).toBeLessThanOrEqual(1);
}

/** Writing rule: no dashes in what people read (code, emails and addresses excluded). */
export async function noDashes(page: Page, label: string) {
  const text = await page.evaluate(() => {
    const skip = 'code, pre, input, textarea, [data-allow-dash]';
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const out: string[] = [];
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      const el = n.parentElement;
      if (!el || el.closest(skip) || !el.checkVisibility?.()) continue;
      if (/[–—]/.test(n.textContent ?? '')) out.push((n.textContent ?? '').trim().slice(0, 120));
    }
    return out;
  });
  expect.soft(text, `${label}: dashes in user facing text`).toEqual([]);
}

/** Only `npm run e2e` starts the separate test stack the tests use, so only it may run them. */
export function requireWrapper() {
  if (!process.env.CI && process.env.E2E_WRAPPED !== '1')
    throw new Error(
      'Run the end to end tests with "npm run e2e" (add -- and Playwright options after it). It starts the separate test stack they use, so your own data is never touched.',
    );
}

/** Put the known test data back (Sandbox starting data plus confirmed and asked class weeks). */
export function loadDemoData() {
  requireWrapper();
  const r = spawnSync(
    process.execPath,
    [join(ROOT, 'node_modules', 'tsx', 'dist', 'cli.mjs'), 'src/demo-data.ts', 'load'],
    { cwd: join(ROOT, 'scripts'), encoding: 'utf8' },
  );
  if (r.status !== 0) throw new Error(`Could not load the test data: ${r.stderr || r.stdout}`);
}

/** Run SQL against the local test database (setup and checks only; the app is tested through the UI). */
export async function sql<T = Record<string, unknown>>(q: string, params: unknown[] = []) {
  const c = new pg.Client({ connectionString: DB_URL });
  await c.connect();
  try {
    return (await c.query(q, params)).rows as T[];
  } finally {
    await c.end();
  }
}

/**
 * Set one field of a page's filter bar (Upcoming classes, Schedule board) to exactly these choices, none to clear
 * it, then close its list. The field's button is named by its visible text: "Cohort", or "Cohort (2)" with two chosen.
 */
export async function setFilter(page: Page, field: string, values: string[]) {
  const bar = page.getByRole('group', { name: 'Filters' });
  await bar.getByRole('button', { name: new RegExp(`^${field}( \\(\\d+\\))?$`) }).click();
  const list = page.getByRole('dialog', { name: field, exact: true });
  await expect(list).toBeVisible();
  const clear = list.getByRole('button', { name: 'Clear', exact: true });
  if (await clear.isEnabled()) await clear.click();
  for (const v of values) await list.getByRole('checkbox', { name: v, exact: true }).check();
  await page.keyboard.press('Escape');
  await expect(list).toHaveCount(0);
  const name = values.length ? `${field} (${values.length})` : field;
  await expect(bar.getByRole('button', { name, exact: true })).toBeVisible();
}
