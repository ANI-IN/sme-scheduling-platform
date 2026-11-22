// Release 3, M11 (decision 304): two cohorts merge into a combined cohort through the app, on the Sandbox starting data.
// Each cohort has Database Design, then API Design a week later; merging from the second week moves the first cohort's
// API Design into the combined cohort and cancels the other's, after a preview. Undo brings both back. The rules
// behind each step are covered in depth by the database test 450.
import type { Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noDashes, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const A = 'E2E Merge A';
const B = 'E2E Merge B';
const C = 'E2E Merge AB';

/** A Saturday about ten weeks ahead, so every class week is still to come. */
const saturday = (() => {
  const d = new Date(Date.now() + 70 * 864e5);
  d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7));
  return d.toISOString().slice(0, 10);
})();
const plusDays = (iso: string, n: number) =>
  new Date(Date.parse(`${iso}T12:00:00Z`) + n * 864e5).toISOString().slice(0, 10);

async function openBackend(page: Page) {
  await page.goto('/setup/domains');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Backend' }).first().click();
  const drawer = page.getByRole('dialog', { name: 'Backend' });
  await expect(drawer).toBeVisible();
  await ready(page);
  return drawer;
}

const weeks = () =>
  sql<{ cohort: string; module: string; status: string }>(
    `select c.name cohort, m.name module, w.status from public.module_week w join public.cohort c on c.id = w.cohort_id
       join public.module m on m.id = w.module_id where c.name in ($1, $2, $3) order by c.name, w.week_start_date`,
    [A, B, C],
  );

test('two cohorts merge into a combined cohort, then the merge is undone', async ({ page }) => {
  for (const name of [A, B])
    await sql(
      `with d as (select id from public.domain where name = 'Backend'),
            c as (insert into public.cohort (domain_id, name, region) select id, $1, 'US' from d returning id)
       select public.add_one_class(null, (select m.id from public.module m, d where m.domain_id = d.id and m.name = x.module),
                (select id from c), x.day, '09:00', '13:00', 'Live class', null, true, 'E2E: test class')
         from (values ('Database Design', $2::date), ('API Design', $3::date)) x(module, day)`,
      [name, saturday, plusDays(saturday, 7)],
    );

  const drawer = await openBackend(page);
  await drawer.getByRole('button', { name: 'Merge cohorts' }).click();
  const dlg = page.getByRole('dialog', { name: 'Merge cohorts' });
  await dlg.getByLabel(A, { exact: true }).check();
  await dlg.getByLabel(B, { exact: true }).check();
  await dlg.getByLabel('Name of the combined cohort').fill(C);
  await dlg.getByLabel('Merge date').fill(plusDays(saturday, 7));
  const list = dlg.getByRole('region', { name: 'Class weeks from the merge date' });
  await expect(list.locator('li')).toHaveCount(2);
  await expect(list.locator('li').filter({ hasText: A })).toContainText(
    'Moves to the combined cohort',
  );
  await expect(list.locator('li').filter({ hasText: B })).toContainText('Cancelled');
  await a11y(page, 'merge cohorts preview');
  await noDashes(page, 'merge cohorts preview');
  await dlg.getByRole('button', { name: 'Merge cohorts', exact: true }).click();
  const anyway = page.getByRole('button', { name: 'Merge anyway' });
  if (await anyway.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await page
      .getByRole('dialog')
      .filter({ has: anyway })
      .getByLabel(/^Reason/)
      .fill('E2E: on purpose');
    await anyway.click();
  }
  await expect(page.getByText(`Cohorts merged into ${C}: 1 class week moved`)).toBeVisible({
    timeout: 20_000,
  });
  const merged = await weeks();
  expect(merged.filter((w) => w.cohort === C).map((w) => w.module)).toEqual(['API Design']);
  expect(merged.filter((w) => w.cohort === A).map((w) => w.module)).toEqual(['Database Design']);
  expect(merged.find((w) => w.cohort === B && w.module === 'API Design')?.status).toBe('Cancelled');
  await expect(drawer.getByText(`Merged into ${C} from`).first()).toBeVisible();

  await drawer.getByRole('button', { name: 'Undo merge' }).first().click();
  await page.getByRole('button', { name: 'Undo merge' }).last().click();
  await expect(page.getByText('Merge undone')).toBeVisible();
  const after = await weeks();
  expect(after.filter((w) => w.cohort === C)).toEqual([]);
  expect(after.find((w) => w.cohort === B && w.module === 'API Design')?.status).not.toBe(
    'Cancelled',
  );
});
