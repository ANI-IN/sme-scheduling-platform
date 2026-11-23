// Release 3, M8 (decision 301): cohort breaks and cohort holidays through the app, on the Sandbox starting data
// (Backend has Database Design and API Design). A cohort with two class weeks, the second one confirmed: a break
// before the second moves it back after a preview and its instructor gets one message; a cohort holiday on the first
// class is kept with a reason; removing the break moves the class week back. The rules behind each step are covered
// in depth by the database test 420.
import type { Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noDashes, ready, setFilter, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const COHORT = 'E2E Break';
const REASON = 'E2E Diwali';
const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

/** A Saturday about ten weeks ahead, so every class week is still to come. */
const saturday = (() => {
  const d = new Date(Date.now() + 70 * 864e5);
  d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7));
  return d.toISOString().slice(0, 10);
})();
const plusDays = (iso: string, n: number) =>
  new Date(Date.parse(`${iso}T12:00:00Z`) + n * 864e5).toISOString().slice(0, 10);

/** Types a reason when the "go ahead anyway?" dialog asks for one, then clicks. Does nothing without it. */
async function goAhead(page: Page, button: string | RegExp, reason: string, ms = 4_000) {
  const b = page.getByRole('button', { name: button });
  if (
    !(await b.waitFor({ timeout: ms }).then(
      () => true,
      () => false,
    ))
  )
    return;
  const box = page
    .getByRole('dialog')
    .filter({ has: b })
    .getByLabel(/^Reason/);
  if (await box.count()) await box.fill(reason);
  await b.click();
}

const weekStart = (module: string) =>
  one<{ start: string }>(
    `select w.week_start_date::text start from public.module_week w join public.cohort c on c.id = w.cohort_id
       join public.module m on m.id = w.module_id where c.name = $1 and m.name = $2`,
    [COHORT, module],
  ).then((r) => r.start);

async function openBackend(page: Page) {
  await page.goto('/setup/domains');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Backend' }).first().click();
  const drawer = page.getByRole('dialog', { name: 'Backend' });
  await expect(drawer).toBeVisible();
  await ready(page);
  return drawer;
}

let confirmed = '';

test('a break for one cohort: the preview first, then the later class week moves', async ({
  page,
}) => {
  // Test data: a cohort with Database Design, then API Design a week later with a confirmed instructor.
  const r = await one<{ who: string }>(
    `with d as (select id from public.domain where name = 'Backend'),
          c as (insert into public.cohort (domain_id, name, region) select id, $1, 'US' from d returning id),
          w1 as (select public.add_one_class(null, (select m.id from public.module m, d where m.domain_id = d.id and m.name = 'Database Design'),
                   (select id from c), $2::date, '09:00', '13:00', 'Live class', null, true, 'E2E: test class') x),
          w2 as (select public.add_one_class(null, (select m.id from public.module m, d where m.domain_id = d.id and m.name = 'API Design'),
                   (select id from c), $3::date, '09:00', '13:00', 'Live class', null, true, 'E2E: test class') x)
     select (select x ->> 'module_week_id' from w1) || ',' || (select x ->> 'module_week_id' from w2) who`,
    [COHORT, saturday, plusDays(saturday, 7)],
  );
  const apiWeek = r.who.split(',')[1]!;
  const pick = await one<{ id: string; name: string }>(
    `select i.id, i.full_name name from public.module_ranking k join public.instructor i on i.id = k.instructor_id
       join public.module_week w on w.module_id = k.module_id where w.id = $1 order by k.rank limit 1`,
    [apiWeek],
  );
  await sql(`select public.assign_manually($1, $2, null, true, 'E2E: confirmed for the test')`, [
    apiWeek,
    pick.id,
  ]);
  confirmed = pick.name;

  const drawer = await openBackend(page);
  await drawer.getByRole('button', { name: 'Add a break' }).click();
  const dlg = page.getByRole('dialog', { name: 'Add a break' });
  await dlg.getByLabel('What is the break for?').fill(REASON);
  await dlg.getByLabel('First day').fill(plusDays(saturday, 7));
  await dlg.getByLabel(COHORT, { exact: true }).check();
  const moves = dlg.getByRole('region', { name: `What moves in ${COHORT}` });
  await expect(moves).toContainText(`${COHORT}: 1 class week moves`);
  await expect(moves).toContainText('API Design');
  await expect(moves).toContainText(`Confirmed: ${confirmed}`);
  await expect(dlg.getByText(/^1 confirmed instructor gets one message/)).toBeVisible();
  // Nothing moves before saving.
  expect(await weekStart('API Design')).toBe(plusDays(saturday, 7));
  await a11y(page, 'add a break preview');
  await noDashes(page, 'add a break preview');
  await dlg.getByRole('button', { name: 'Add break', exact: true }).click();
  await goAhead(page, 'Add break anyway', 'E2E: the break on purpose');
  await expect(page.getByText('Break added: 1 class week moved')).toBeVisible({ timeout: 20_000 });

  expect(await weekStart('Database Design')).toBe(saturday);
  expect(await weekStart('API Design')).toBe(plusDays(saturday, 14));
  const m = await one<{ n: number }>(
    `select count(*)::int n from public.message where template_id = 'M17' and module_week_id = $1 and channel = 'Email'`,
    [apiWeek],
  );
  expect(m.n).toBe(1);
  await expect(drawer.getByRole('list', { name: 'Breaks' })).toContainText(`${COHORT}: ${REASON}`);
});

test('a cohort holiday shows on its class, which can be kept with a reason', async ({ page }) => {
  const drawer = await openBackend(page);
  await drawer.getByRole('button', { name: 'Add a cohort holiday' }).click();
  const dlg = page.getByRole('dialog', { name: 'Add a cohort holiday' });
  await dlg.getByLabel('Cohort').selectOption({ label: COHORT });
  await dlg.getByRole('textbox', { name: 'Day', exact: true }).fill(saturday);
  await dlg.getByLabel('Name').fill('E2E Founders day');
  await dlg.getByRole('button', { name: 'Add holiday' }).click();
  await expect(dlg.getByText('Holiday added. 1 class is on that day:')).toBeVisible();
  await a11y(page, 'cohort holiday added');
  await noDashes(page, 'cohort holiday added');
  await dlg.getByRole('button', { name: 'Done' }).click();

  await page.goto('/classes');
  await ready(page);
  await setFilter(page, 'Cohort', [COHORT]);
  await ready(page);
  await page
    .getByRole('button', { name: /^Open Database Design, week of/ })
    .first()
    .click();
  const week = page.getByRole('dialog', { name: /^Database Design: week of/ });
  await expect(week).toBeVisible();
  await expect(week.getByText(/is on a holiday of this cohort \(E2E Founders day\)/)).toBeVisible();
  await week.getByRole('button', { name: 'Keep with a reason' }).click();
  const keep = page.getByRole('dialog', { name: 'Keep the class on the holiday?' });
  await keep.getByLabel('Reason').fill('E2E: the class stays');
  await keep.getByRole('button', { name: 'Keep class' }).click();
  await expect(page.getByText('Class kept on the holiday')).toBeVisible();
  await expect(week.getByText(/Kept: E2E: the class stays\./)).toBeVisible();
});

test('removing the break moves the class week back', async ({ page }) => {
  const drawer = await openBackend(page);
  await drawer.getByRole('button', { name: `Remove the break ${REASON}` }).click();
  const dlg = page.getByRole('dialog', { name: `Remove the break ${REASON}?` });
  await expect(dlg.getByRole('region', { name: `What moves in ${COHORT}` })).toContainText(
    'API Design',
  );
  await a11y(page, 'remove a break preview');
  await noDashes(page, 'remove a break preview');
  await dlg.getByRole('button', { name: 'Remove break', exact: true }).click();
  await goAhead(page, 'Remove break anyway', 'E2E: back to the plan');
  await expect(page.getByText('Break removed: 1 class week moved back')).toBeVisible({
    timeout: 20_000,
  });
  expect(await weekStart('API Design')).toBe(plusDays(saturday, 7));
  const h = await one<{ n: number }>(
    `select count(*)::int n from public.history_event where action in ('Break added: ' || $1, 'Break removed: ' || $1)`,
    [REASON],
  );
  expect(h.n).toBe(2);
});
