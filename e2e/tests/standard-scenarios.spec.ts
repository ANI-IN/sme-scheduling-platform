// Release 3, M7b (decisions 298 and 299): standard schedules through the app, on the Sandbox starting data (Backend
// has Database Design, API Design and Concurrency). A standard with two modules and a break, two cohorts planned
// from it at once, one of them customized and reset, the standard changed and its cohorts updated (a customized and
// a confirmed class week are "Not updated" with the reason), and a cohort that starts fully custom. The rules behind
// each step are covered in depth by the database tests 390 and 400.
import type { Locator, Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noDashes, ready, setFilter, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const TRACK = 'E2E track';
const ALPHA = 'E2E Alpha';
const BETA = 'E2E Beta';
const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

/** A Saturday about ten weeks ahead, so every class week is still to come and nobody is asked yet. */
const saturday = (() => {
  const d = new Date(Date.now() + 70 * 864e5);
  d.setUTCDate(d.getUTCDate() + ((6 - d.getUTCDay() + 7) % 7));
  return d.toISOString().slice(0, 10);
})();
const plusDays = (iso: string, n: number) =>
  new Date(Date.parse(`${iso}T12:00:00Z`) + n * 864e5).toISOString().slice(0, 10);

/**
 * The "go ahead anyway?" dialog (decision 297): a Warning needs a reason before its button works, so type one
 * when the dialog asks, then click. Does nothing when the dialog does not appear.
 */
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

/** A class week of a cohort by its place in the standard. */
const week = (cohort: string, pos: number) =>
  one<{ id: string; customized_at: string | null; live: string; classes: number }>(
    `select w.id, w.customized_at,
            (select to_char(k.starts_at at time zone 'America/Los_Angeles', 'HH24:MI') from public.class_session k
              where k.module_week_id = w.id and k.status = 'Planned' and k.class_type = 'Live class') live,
            (select count(*)::int from public.class_session k where k.module_week_id = w.id and k.status = 'Planned') classes
       from public.module_week w join public.cohort c on c.id = w.cohort_id
      where c.name = $1 and w.standard_position = $2`,
    [cohort, pos],
  );

/** Open the standard schedule's drawer from the Standard schedules page. */
async function openTrack(page: Page) {
  await page.goto('/setup/standards');
  await ready(page);
  await page.getByRole('button', { name: TRACK, exact: true }).click();
  const drawer = page.getByRole('dialog', { name: TRACK });
  await expect(drawer).toBeVisible();
  await ready(page);
  return drawer;
}

/** Open the class drawer of the first class week of a cohort (Database Design, the first module). */
async function openFirstWeek(page: Page, cohort: string) {
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

/** The row of a cohort in the standard's "Cohorts following it" list. */
const cohortRow = (drawer: Locator, name: string) => drawer.locator('li').filter({ hasText: name });

test('a standard schedule with two modules and a break', async ({ page }) => {
  await page.goto('/setup/standards');
  await ready(page);
  await expect(page.getByText('No standard schedules yet')).toBeVisible();
  await page.getByRole('button', { name: 'Add standard schedule' }).first().click();
  const dlg = page.getByRole('dialog', { name: 'Add standard schedule' });
  await dlg.getByLabel('Name').fill(TRACK);
  for (const m of ['Database Design', 'API Design']) {
    await dlg.getByRole('combobox', { name: 'Module to add' }).selectOption({ label: m });
    await dlg.getByRole('button', { name: 'Add module' }).click();
  }
  await dlg.getByRole('button', { name: 'Add a break' }).click();
  await expect(dlg.getByRole('combobox', { name: /^After module/ })).toHaveValue('1');
  await a11y(page, 'add standard schedule dialog');
  await noDashes(page, 'add standard schedule dialog');
  await dlg.getByRole('button', { name: 'Add standard schedule' }).click();
  await expect(page.getByText(`Standard schedule ${TRACK} added`)).toBeVisible();

  // It opens to finish it: each module uses its own class times until the standard has its own.
  const drawer = page.getByRole('dialog', { name: TRACK });
  await expect(drawer).toBeVisible();
  await expect(
    drawer.getByRole('region', { name: 'Class times of Database Design in this standard' }),
  ).toContainText("Uses the module's own class times");
  await page.keyboard.press('Escape');
  const row = page.locator('tbody tr').filter({ hasText: TRACK });
  await expect(row).toContainText('Database Design');
  await expect(row).toContainText('API Design');
  await expect(row).toContainText('1 week after module 1');

  const s = await one<{ modules: string; breaks: string }>(
    `select (select string_agg(m.name, ', ' order by x.position) from public.standard_schedule_module x
              join public.module m on m.id = x.module_id where x.schedule_id = s.id) modules,
            (select string_agg(b.after_position || ':' || b.weeks, ',') from public.standard_schedule_break b
              where b.schedule_id = s.id) breaks
       from public.standard_schedule s where s.name = $1`,
    [TRACK],
  );
  expect(s).toEqual({ modules: 'Database Design, API Design', breaks: '1:1' });
});

test('two cohorts planned from the standard at once, with every class week shown first', async ({
  page,
}) => {
  await page.goto('/setup/standards');
  await ready(page);
  await page.getByRole('button', { name: 'Plan cohorts' }).click();
  const dlg = page.getByRole('dialog', { name: 'Plan cohorts from a standard' });
  await expect(dlg.getByLabel('Standard schedule')).toHaveValue(/.+/);
  await dlg.getByRole('button', { name: 'Add another cohort' }).click();
  await dlg.getByLabel('Name of cohort 1').fill(ALPHA);
  await dlg.getByLabel('Start date of cohort 1').fill(saturday);
  await dlg.getByLabel('Name of cohort 2').fill(BETA);
  await dlg.getByLabel('Start date of cohort 2').fill(plusDays(saturday, 7));
  await dlg.getByRole('button', { name: 'Show the plan' }).click();

  await expect(dlg.getByText(/2 new cohorts, 4 class weeks/)).toBeVisible();
  for (const c of [ALPHA, BETA]) {
    const weeks = dlg.getByRole('region', { name: `Class weeks of ${c}` }).locator('tbody tr');
    await expect(weeks).toHaveCount(2);
    await expect(weeks.nth(0)).toContainText('1. Database Design');
    await expect(weeks.nth(1)).toContainText('2. API Design');
  }
  await a11y(page, 'plan cohorts from a standard');
  await noDashes(page, 'plan cohorts from a standard');
  await dlg.getByRole('button', { name: 'Create 2 cohorts' }).click();
  await goAhead(page, 'Plan anyway', 'E2E: two cohorts from the standard on purpose');
  await expect(page.getByText('Planned 2 cohorts with 4 class weeks')).toBeVisible({
    timeout: 20_000,
  });

  // The break: API Design starts two weeks after Database Design.
  const r = await sql<{ cohort: string; pos: number; start: string }>(
    `select c.name cohort, w.standard_position pos, w.week_start_date::text start
       from public.module_week w join public.cohort c on c.id = w.cohort_id
      where c.name in ($1, $2) order by c.name, w.standard_position`,
    [ALPHA, BETA],
  );
  expect(r).toEqual([
    { cohort: ALPHA, pos: 1, start: saturday },
    { cohort: ALPHA, pos: 2, start: plusDays(saturday, 14) },
    { cohort: BETA, pos: 1, start: plusDays(saturday, 7) },
    { cohort: BETA, pos: 2, start: plusDays(saturday, 21) },
  ]);
  const drawer = await openTrack(page);
  await expect(cohortRow(drawer, ALPHA)).toContainText(`Standard: ${TRACK}`);
  await expect(cohortRow(drawer, BETA)).toContainText(`Standard: ${TRACK}`);
});

test('one cohort is customized; the other stays Standard', async ({ page }) => {
  const drawer = await openFirstWeek(page, ALPHA);
  await expect(drawer.getByText('It follows its standard.')).toBeVisible();
  await drawer.getByLabel('Start time').first().fill('10:00');
  await drawer.getByLabel('End time').first().fill('14:00');
  await drawer.getByRole('button', { name: 'Change time' }).first().click();
  await page.getByRole('button', { name: 'Yes, continue' }).click();
  await goAhead(page, 'Change anyway', 'E2E: a later start for this cohort');
  await expect(page.getByText('Class time changed')).toBeVisible();
  await expect(drawer.getByText(/^Changed for this cohort on /)).toBeVisible();
  await expect(drawer.getByText('Custom', { exact: true })).toBeVisible();
  expect((await week(ALPHA, 1)).customized_at).not.toBeNull();

  const track = await openTrack(page);
  await expect(cohortRow(track, ALPHA)).toContainText('Custom (1 change)');
  await expect(cohortRow(track, BETA)).toContainText(`Standard: ${TRACK}`);
  expect((await week(BETA, 1)).customized_at).toBeNull();
});

test('Reset to standard brings the class week back', async ({ page }) => {
  const drawer = await openFirstWeek(page, ALPHA);
  await drawer.getByRole('button', { name: 'Reset to standard' }).click();
  const dlg = page.getByRole('dialog', { name: 'Reset this class week to standard?' });
  await expect(dlg.getByText(/^Move Database Design: Live class from /)).toBeVisible();
  await a11y(page, 'reset to standard preview');
  await noDashes(page, 'reset to standard preview');
  await dlg.getByRole('button', { name: 'Reset', exact: true }).click();
  await goAhead(page, 'Reset anyway', 'E2E: back to the standard');
  await expect(page.getByText('Reset to standard: 1 class week changed')).toBeVisible();
  const w = await week(ALPHA, 1);
  expect(w.customized_at).toBeNull();
  expect(w.live).toBe('09:00');

  const track = await openTrack(page);
  await expect(cohortRow(track, ALPHA)).toContainText(`Standard: ${TRACK}`);
});

test('the standard changes: its cohorts are updated, except a customized and a confirmed week', async ({
  page,
}) => {
  // Test data: Alpha's second class week changed on its own, and an instructor confirmed for Beta's first.
  await sql(
    `update public.class_session k set starts_at = k.starts_at + interval '1 hour', ends_at = k.ends_at + interval '1 hour'
      where k.module_week_id = $1 and k.class_type = 'Live class'`,
    [(await week(ALPHA, 2)).id],
  );
  const instructor = await one<{ id: string }>(
    `select id from public.instructor where full_name = 'Test Instructor A'`,
  );
  await sql(
    `select public.assign_manually(p_module_week_id => $1, p_instructor_id => $2,
              p_accept_warnings => true, p_reason => 'E2E: confirmed on purpose')`,
    [(await week(BETA, 1)).id, instructor.id],
  );
  expect((await week(ALPHA, 2)).customized_at).not.toBeNull();

  // The standard gets its own class time for Database Design: one live class at 10:00.
  const drawer = await openTrack(page);
  const times = drawer.getByRole('region', {
    name: 'Class times of Database Design in this standard',
  });
  await times.getByLabel('Class type').selectOption('Live class');
  await times.getByLabel('Day').selectOption({ label: 'Sunday' });
  await times.getByLabel('Starts (local time)').fill('10:00');
  await times.getByLabel('Length in minutes').fill('240');
  await times.getByRole('button', { name: 'Add class' }).click();
  await expect(page.getByText('Class time added')).toBeVisible();
  await expect(times.locator('tbody tr')).toHaveCount(1);
  // Nothing changes for the cohorts until Update cohorts.
  expect((await week(ALPHA, 1)).live).toBe('09:00');

  await drawer.getByRole('button', { name: 'Update cohorts' }).click();
  const dlg = page.getByRole('dialog', { name: `Update cohorts from ${TRACK}` });
  await expect(dlg.getByText('What changes (1 class week)')).toBeVisible();
  await expect(dlg.getByText(/^Move Database Design: Live class from /)).toBeVisible();
  await expect(dlg.getByText(/^Cancel Database Design: Assignment review/)).toBeVisible();
  await expect(dlg.getByText('Not updated (2)')).toBeVisible();
  await expect(
    dlg.getByText(
      /^Changed for this cohort on .+\. Use Reset to standard on the class week to bring it back\.$/,
    ),
  ).toBeVisible();
  await expect(
    dlg.getByText(
      'An instructor is confirmed. Change the time on the class week, so they are asked about the new time.',
    ),
  ).toBeVisible();
  // The "Class time added" toast fades out first, so its half faded text is not what is checked.
  await expect(page.locator('[data-sonner-toast]')).toHaveCount(0, { timeout: 10_000 });
  await a11y(page, 'update cohorts preview');
  await noDashes(page, 'update cohorts preview');
  await dlg.getByRole('button', { name: 'Update cohorts', exact: true }).click();
  await goAhead(page, 'Update anyway', 'E2E: the new standard time');
  await expect(page.getByText(/^Cohorts updated: 1 class week changed/)).toBeVisible({
    timeout: 20_000,
  });

  const a1 = await week(ALPHA, 1);
  expect([a1.live, a1.classes, a1.customized_at]).toEqual(['10:00', 1, null]);
  expect((await week(BETA, 1)).live).toBe('09:00');
  expect((await week(ALPHA, 2)).customized_at).not.toBeNull();
  const track = await openTrack(page);
  await expect(cohortRow(track, ALPHA)).toContainText('Custom (1 change)');
  await expect(cohortRow(track, BETA)).toContainText(`Standard: ${TRACK}`);

  const h = await sql<{ action: string }>(
    `select distinct action from public.history_event
      where action in ('Cohorts planned from a standard', 'Reset to standard', $1) order by action`,
    [`Standard applied: ${TRACK}`],
  );
  expect(h.map((x) => x.action)).toEqual([
    'Cohorts planned from a standard',
    'Reset to standard',
    `Standard applied: ${TRACK}`,
  ]);
});

test('a cohort added by hand is fully custom', async ({ page }) => {
  await page.goto('/setup/domains');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Backend' }).first().click();
  const drawer = page.getByRole('dialog', { name: 'Backend' });
  await expect(drawer).toBeVisible();
  await ready(page);
  await drawer.getByLabel('New cohort', { exact: true }).fill('E2E Free');
  await drawer.getByRole('button', { name: 'Add cohort' }).click();
  await expect(page.getByText('Cohort E2E Free added')).toBeVisible();
  await expect(drawer.locator('li').filter({ hasText: 'E2E Free' })).toContainText('Fully custom');
  await expect(drawer.locator('li').filter({ hasText: ALPHA })).toContainText('Custom (1 change)');
  await expect(
    drawer
      .locator('li')
      .filter({ hasText: ALPHA })
      .getByRole('button', { name: `Reset ${ALPHA} to standard` }),
  ).toBeVisible();
  await expect(drawer.locator('li').filter({ hasText: 'Weekend cohort' })).toContainText(
    'Fully custom',
  );
  const c = await one<{ standard_schedule_id: string | null }>(
    `select standard_schedule_id from public.cohort where name = 'E2E Free'`,
  );
  expect(c.standard_schedule_id).toBeNull();
});
