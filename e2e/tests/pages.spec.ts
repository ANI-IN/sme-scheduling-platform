// Every page, drawer and dialog: loads without errors, passes axe, and fits a phone screen.
// Runs in four projects: desktop and mobile, light and dark.
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import type { Page } from '@playwright/test';
import { ROOT } from '../env.ts';
import { a11y, expect, noDashes, noSidewaysScroll, ready, sql, test } from './fixtures.ts';

const guides = readdirSync(join(ROOT, 'app', 'src', 'help'))
  .filter((f) => f.endsWith('.md'))
  .map((f) => `/help/${f.replace(/\.md$/, '')}`);

const PAGES = [
  '/',
  '/classes',
  '/requests',
  '/setup/modules',
  '/setup/modules/new',
  'MODULE',
  '/setup/instructors',
  '/setup/team',
  '/setup/domains',
  '/settings/automation',
  '/settings/messages',
  '/settings/testing',
  '/settings/connections',
  '/activity',
  '/help',
  ...guides,
];

const MODULE_TABS = ['times', 'order', 'owners', 'operations', 'materials', 'next'];

async function firstModule() {
  const [m] = await sql<{ id: string }>(
    `select m.id from public.module m join public.domain d on d.id = m.domain_id
      where d.name = 'Backend' order by m.name limit 1`,
  );
  return `/setup/modules/${m!.id}`;
}

async function visit(page: Page, path: string) {
  await page.goto(path);
  await ready(page);
  await expect(page.getByRole('heading', { level: 1 }).first()).toBeVisible();
}

const mobile = (page: Page) => (page.viewportSize()?.width ?? 1280) < 768;

for (const path of PAGES) {
  test(`page ${path === 'MODULE' ? 'module detail' : path}`, async ({ page }) => {
    const p = path === 'MODULE' ? await firstModule() : path;
    await visit(page, p);
    await a11y(page, p);
    await noDashes(page, p);
    if (mobile(page)) await noSidewaysScroll(page, p);
  });
}

for (const tab of MODULE_TABS) {
  test(`module tab ${tab}`, async ({ page }) => {
    const p = `${await firstModule()}?tab=${tab}`;
    await visit(page, p);
    await a11y(page, p);
    await noDashes(page, p);
    if (mobile(page)) await noSidewaysScroll(page, p);
  });
}

test('automation settings for a cohort', async ({ page }) => {
  const [c] = await sql<{ id: string }>(`select id from public.cohort order by name limit 1`);
  await visit(page, `/settings/automation?scope=Cohort&id=${c!.id}`);
  await a11y(page, 'automation settings for a cohort');
});

test('signed out: the sign in page', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  const errors: string[] = [];
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  await page.goto('/');
  await expect(page.getByRole('button', { name: /sign in with google/i })).toBeVisible();
  await a11y(page, 'sign in page');
  expect(errors).toEqual([]);
  await ctx.close();
});

/** Drawers, dialogs and menus, opened the way people open them. */
const OPENERS: { name: string; path: string; open: (page: Page) => Promise<void> }[] = [
  {
    name: 'class drawer',
    path: '/classes',
    open: (p) => p.locator('tbody tr').filter({ hasText: 'Confirmed' }).first().click(),
  },
  {
    name: 'plan classes dialog',
    path: '/classes',
    open: (p) => p.getByRole('button', { name: 'Plan classes' }).click(),
  },
  {
    name: 'add one class dialog',
    path: '/classes',
    open: (p) => p.getByRole('button', { name: 'Add one class' }).click(),
  },
  {
    name: 'instructor drawer',
    path: '/setup/instructors',
    open: (p) => p.locator('tbody tr').first().click(),
  },
  {
    name: 'add instructor',
    path: '/setup/instructors',
    open: (p) => p.getByRole('button', { name: 'Add instructor' }).first().click(),
  },
  {
    name: 'team member drawer',
    path: '/setup/team',
    open: (p) => p.locator('tbody tr').first().click(),
  },
  {
    name: 'domain drawer',
    path: '/setup/domains',
    open: (p) => p.locator('tbody tr').first().click(),
  },
  {
    name: 'create domain',
    path: '/setup/domains',
    open: (p) => p.getByRole('button', { name: 'Create domain' }).first().click(),
  },
  {
    name: 'help request',
    path: '/',
    open: (p) => p.getByRole('button', { name: 'Open help request', exact: true }).first().click(),
  },
  {
    name: 'account menu',
    path: '/',
    open: async (p) => {
      if (mobile(p)) await p.getByRole('button', { name: /open menu/i }).click();
      await p.getByRole('button', { name: /your account and theme/i }).click();
    },
  },
];

for (const o of OPENERS) {
  test(`open ${o.name}`, async ({ page }) => {
    await visit(page, o.path);
    await o.open(page);
    await page.waitForTimeout(400);
    await ready(page);
    const layer = page.locator('[role="dialog"], [role="menu"]').last();
    await expect(layer).toBeVisible();
    await a11y(page, o.name);
    await noDashes(page, o.name);
    if (mobile(page)) await noSidewaysScroll(page, o.name);
  });
}
