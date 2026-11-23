// Release 3, M10 (decision 303): one class shared by two cohorts through the app, on the Sandbox starting data. Two
// cohorts each have a Database Design class at the same time; the first shares its class with the second after a
// preview, the second shows Shared class and is not asked, and Stop sharing gives it its own class week back. The
// rules behind each step are covered in depth by the database test 440.
import type { Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noDashes, ready, setFilter, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const HOST = 'E2E Share A';
const GUEST = 'E2E Share B';
const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

/** A Saturday about ten weeks ahead, so the class is still to come and nobody is asked yet. */
const saturday = (() => {
  const d = new Date(Date.now() + 70 * 864e5);
  d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7));
  return d.toISOString().slice(0, 10);
})();

async function openWeek(page: Page, cohort: string) {
  await page.goto('/classes');
  await ready(page);
  await setFilter(page, 'Cohort', [cohort]);
  await ready(page);
  await page
    .getByRole('button', { name: /^Open Database Design, week of/ })
    .first()
    .click();
  const drawer = page.getByRole('dialog', { name: /^Database Design: week of/ });
  await expect(drawer).toBeVisible();
  await ready(page);
  return drawer;
}

const guest = () =>
  one<{ shared: boolean; paused: boolean }>(
    `select w.shared_with is not null shared, w.paused from public.module_week w join public.cohort c on c.id = w.cohort_id
      where c.name = $1`,
    [GUEST],
  );

test('a class shared by two cohorts, then given back', async ({ page }) => {
  for (const name of [HOST, GUEST])
    await sql(
      `with d as (select id from public.domain where name = 'Backend'),
            c as (insert into public.cohort (domain_id, name, region) select id, $1, 'US' from d returning id)
       select public.add_one_class(null, (select m.id from public.module m, d where m.domain_id = d.id and m.name = 'Database Design'),
                (select id from c), $2::date, '09:00', '13:00', 'Live class', null, true, 'E2E: test class')`,
      [name, saturday],
    );

  const drawer = await openWeek(page, HOST);
  await drawer.getByRole('button', { name: 'Share with other cohorts' }).click();
  const dlg = page.getByRole('dialog', { name: 'Share this class with other cohorts' });
  await dlg.getByLabel(new RegExp(`^${GUEST}: Database Design`)).check();
  await expect(dlg.getByRole('region', { name: 'What happens' })).toContainText(
    'The other class weeks are not asked while they share this class.',
  );
  await a11y(page, 'share a class preview');
  await noDashes(page, 'share a class preview');
  await dlg.getByRole('button', { name: 'Share class' }).click();
  const anyway = page.getByRole('button', { name: 'Share anyway' });
  if (await anyway.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await page
      .getByRole('dialog')
      .filter({ has: anyway })
      .getByLabel(/^Reason/)
      .fill('E2E: on purpose');
    await anyway.click();
  }
  await expect(page.getByText('Class shared with 1 other class week')).toBeVisible({
    timeout: 20_000,
  });
  expect(await guest()).toEqual({ shared: true, paused: true });
  await expect(drawer.getByRole('list', { name: 'Cohorts sharing this class' })).toContainText(
    GUEST,
  );

  const other = await openWeek(page, GUEST);
  await expect(other.getByText('Shared class', { exact: true }).first()).toBeVisible();
  await expect(other.getByText(/^Taught together with/)).toBeVisible();
  await other.getByRole('button', { name: 'Stop sharing' }).click();
  await page.getByRole('button', { name: 'Stop sharing' }).last().click();
  await expect(page.getByText(/^No longer shared/)).toBeVisible();
  expect(await guest()).toEqual({ shared: false, paused: false });
});
