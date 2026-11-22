// Release 3 M6 (decision 294): time limits per page with a program the size of the team's tracker.
// Runs only with `npm run e2e:scale`, which adds 6 domains with 60 cohorts, 160 instructors and 1,560 class weeks to
// the usual test data (supabase/tests/fixtures/scale_data.sql). Each page must show its data, with no loading
// placeholders left, within its limit; the time each page took is kept in the test report.
import { expect, ready, sql, test } from './fixtures.ts';

/** Seconds from opening the page to its data on screen. */
const LIMIT_S = 8;

const PAGES = [
  '/',
  '/board',
  '/classes',
  '/requests',
  '/setup/modules',
  '/setup/instructors',
  '/setup/domains',
  '/setup/team',
  '/settings/automation',
  '/activity',
];

test.beforeAll(async () => {
  const [n] = await sql<{ n: number }>(`select count(*)::int as n from public.cohort`);
  expect(n!.n, 'the scale data is loaded (npm run e2e:scale)').toBeGreaterThanOrEqual(60);
});

test.beforeEach(async ({ page }) => {
  // The largest domain of the scale data is the one chosen in the app.
  const [d] = await sql<{ id: string }>(
    `select d.id from public.domain d join public.module_week w on w.domain_id = d.id
      group by d.id order by count(*) desc, d.name limit 1`,
  );
  await page.addInitScript((id) => localStorage.setItem('ik-domain', id), d!.id);
});

for (const path of PAGES) {
  test(`page ${path} shows its data within ${LIMIT_S} seconds`, async ({ page }, info) => {
    const started = Date.now();
    await page.goto(path);
    await ready(page);
    await expect(page.getByRole('heading', { level: 1 }).first()).toBeVisible();
    const seconds = (Date.now() - started) / 1000;
    info.annotations.push({ type: 'seconds', description: seconds.toFixed(1) });
    console.log(`${path}: ${seconds.toFixed(1)} s`);
    expect(seconds, `${path} took ${seconds.toFixed(1)} s`).toBeLessThan(LIMIT_S);
  });
}

test('the class list reads every class week of the domain', async ({ page }) => {
  const [d] = await sql<{ name: string; n: number }>(
    `select d.name, count(*)::int as n from public.domain d join public.module_week w on w.domain_id = d.id
      group by d.id order by count(*) desc, d.name limit 1`,
  );
  const weeks: number[] = [];
  page.on('response', async (r) => {
    if (r.url().includes('/rest/v1/module_week') && r.request().method() === 'GET')
      weeks.push(((await r.json().catch(() => [])) as unknown[]).length);
  });
  await page.goto('/classes');
  await ready(page);
  await expect(page.getByRole('heading', { level: 1 }).first()).toBeVisible();
  expect(
    weeks.reduce((a, b) => a + b, 0),
    `class weeks read for ${d!.name}`,
  ).toBeGreaterThanOrEqual(d!.n);
});
