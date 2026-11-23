// Scenario tests through the app, on the Sandbox starting data (Backend and Fullstack, each with a
// weekend and a weekday cohort, six test instructors). The automation rules behind each scenario
// are also covered in depth by the database tests (supabase/tests/database); here we check that a
// person can do each one in the app and that the result lands in the database.
import type { Locator, Page } from '@playwright/test';
import { EMAIL, signInLink } from '../env.ts';
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
test.beforeAll(() => loadDemoData());

/** Click an optional follow up button (a warning or a question) if it shows up. */
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

async function ifShown(l: Locator, ms = 4_000) {
  if (
    await l.waitFor({ timeout: ms }).then(
      () => true,
      () => false,
    )
  )
    await l.click();
}

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

async function backendModule(name = 'Database Design') {
  return one<{ id: string; version: number }>(
    `select m.id, m.version from public.module m join public.domain d on d.id = m.domain_id
      where d.name = 'Backend' and m.name = $1`,
    [name],
  );
}

/** Open the class drawer for the first class week that matches a cohort and a status text. */
async function openWeek(page: Page, cohort: string, has: RegExp) {
  await page.goto('/classes');
  await ready(page);
  await page.getByRole('combobox', { name: 'Cohort' }).selectOption({ label: cohort });
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: has }).first().click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await ready(page);
}

const nextDow = (from: Date, dow: number) => {
  const d = new Date(from);
  d.setUTCDate(d.getUTCDate() + ((dow - d.getUTCDay() + 7) % 7 || 7));
  return d.toISOString().slice(0, 10);
};

test('weekend and weekday cohorts run at the same time', async ({ page }) => {
  const rows = await sql<{ name: string; first: string; last: string; days: string }>(
    `select c.name, min(w.week_start_date)::text first, max(w.week_start_date)::text last,
            string_agg(distinct to_char(s.starts_at at time zone 'America/Los_Angeles', 'Dy'), ',') days
       from public.module_week w join public.cohort c on c.id = w.cohort_id
       join public.domain d on d.id = w.domain_id
       join public.class_session s on s.module_week_id = w.id
      where d.name = 'Backend' group by c.name order by c.name`,
  );
  expect(rows.map((r) => r.name)).toEqual(['Weekday cohort', 'Weekend cohort']);
  // The two cohorts overlap in time.
  expect(rows[0]!.first <= rows[1]!.last && rows[1]!.first <= rows[0]!.last).toBe(true);
  expect(rows[0]!.days).toMatch(/Tue/);
  expect(rows[1]!.days).toMatch(/Sat/);

  await page.goto('/classes');
  await ready(page);
  const cohort = page.getByRole('combobox', { name: 'Cohort' });
  await cohort.selectOption({ label: 'Weekday cohort' });
  await expect(page.locator('tbody tr').first()).toContainText(/Tue/);
  await cohort.selectOption({ label: 'Weekend cohort' });
  await expect(page.locator('tbody tr').first()).toContainText(/Sat/);

  // Plan a third cohort in the same weeks from the app.
  await page.getByRole('button', { name: 'Plan classes' }).click();
  const dlg = page.getByRole('dialog');
  await dlg.getByLabel('Cohort').first().selectOption({ label: 'New cohort' });
  await dlg.getByLabel('Name of the new cohort').fill('E2E Evening');
  await dlg
    .getByLabel('Date of the first class')
    .fill(nextDow(new Date(Date.now() + 21 * 864e5), 3));
  await dlg.getByLabel('Number of class weeks').fill('2');
  await dlg.getByRole('button', { name: 'Show the plan' }).click();
  await dlg.getByRole('button', { name: /^Create 2 class weeks$/ }).click();
  // Classes about four weeks away are a warning (short notice), so the app may ask first.
  const anyway = page.getByRole('button', { name: 'Plan anyway' });
  const planned = page.getByText('Planned 2 class weeks for E2E Evening');
  await expect(anyway.or(planned).first()).toBeVisible({ timeout: 20_000 });
  if (await anyway.isVisible()) await goAhead(page, 'Plan anyway', 'E2E: these dates on purpose');
  await expect(planned).toBeVisible({ timeout: 20_000 });
  const made = await one<{ n: number }>(
    `select count(*)::int n from public.module_week w join public.cohort c on c.id = w.cohort_id
      where c.name = 'E2E Evening'`,
  );
  expect(made.n).toBe(2);
});

test('the same instructor teaches in two cohorts', async ({ page }) => {
  // Someone confirmed for a weekend class week is also assigned a weekday class week.
  const confirmed = await sql<{ id: string; full_name: string }>(
    `select distinct i.id, i.full_name from public.booking b
       join public.instructor i on i.id = b.instructor_id
       join public.module_week w on w.id = b.module_week_id
       join public.cohort c on c.id = w.cohort_id
      where c.name = 'Weekend cohort' and b.status = 'Active'`,
  );
  expect(confirmed.length).toBeGreaterThan(0);
  await openWeek(page, 'Weekday cohort', /Needs instructor|Not asked yet|Waiting for an answer/);
  const dlg = page.getByRole('dialog');
  const select = dlg.getByRole('combobox', { name: 'Instructor', exact: true });
  const options = (await select.locator('option').allTextContents()).map((o) => o.trim());
  const label = (name: string) => options.find((o) => o === name || o.startsWith(`${name} (`));
  const pick = confirmed.find((c) => label(c.full_name));
  expect(
    pick,
    `one of ${confirmed.map((c) => c.full_name).join(', ')} in ${options.join(', ')}`,
  ).toBeTruthy();
  await select.selectOption({ label: label(pick!.full_name)! });
  await dlg.getByRole('button', { name: 'Assign and confirm instructor' }).click();
  await goAhead(page, /yes, continue|assign anyway/i, 'E2E: this instructor on purpose');
  await expect(dlg.getByText(new RegExp(`Confirmed: ${pick!.full_name}`))).toBeVisible();
  const cohorts = await one<{ n: number }>(
    `select count(distinct w.cohort_id)::int n from public.booking b
       join public.module_week w on w.id = b.module_week_id
      where b.instructor_id = $1 and b.status = 'Active'`,
    [pick!.id],
  );
  expect(cohorts.n).toBe(2);
});

test('a confirmed class moves to a weekday and the instructor is asked to confirm', async ({
  page,
}) => {
  await openWeek(page, 'Weekend cohort', /Confirmed/);
  const dlg = page.getByRole('dialog');
  const title = await dlg.getByRole('heading').first().textContent();
  const date = dlg.getByRole('textbox', { name: 'Date' }).first();
  const old = await date.inputValue();
  const wed = nextDow(new Date(old + 'T12:00:00Z'), 3);
  await date.fill(wed);
  await dlg.getByRole('button', { name: 'Change time' }).first().click();
  await page.getByRole('button', { name: 'Yes, continue' }).click();
  await expect(page.getByText('Class time changed')).toBeVisible();
  const r = await one<{ n: number }>(
    `select count(*)::int n from public.request r join public.class_session s on s.module_week_id = r.module_week_id
      where r.kind = 'TimeChange' and (s.starts_at at time zone 'America/Los_Angeles')::date = $1`,
    [wed],
  );
  expect(r.n, `time change request for ${title}`).toBeGreaterThan(0);
});

test('a one off class, and a warning accepted with a reason', async ({ page }) => {
  // A class on a holiday needs a reason. Reset Sandbox data removes the holidays, so add one if a spec
  // before this one reset the data.
  await sql(
    `insert into public.holiday (domain_id, date, name)
     select null, (current_date + 45), 'E2E holiday'
      where not exists (select 1 from public.holiday where date > now())`,
  );
  const hol = await one<{ date: string }>(
    `select date::text from public.holiday where date > now() order by date limit 1`,
  );
  await page.goto('/classes');
  await ready(page);
  await page.getByRole('button', { name: 'Add one class' }).click();
  const dlg = page.getByRole('dialog');
  await dlg.getByLabel('Module').selectOption({ label: 'Database Design' });
  await dlg.getByLabel('Cohort').selectOption({ label: 'Weekday cohort' });
  await dlg.getByLabel('Date').fill(hol.date);
  await dlg.getByLabel('Start time').fill('10:00');
  await dlg.getByLabel('End time').fill('11:00');
  await dlg.getByLabel('Title (optional)').fill('E2E office hours');
  await dlg.getByRole('button', { name: 'Add class' }).click();
  const warn = page.getByRole('dialog', { name: 'Add this class anyway?' });
  await expect(warn).toBeVisible();
  await warn.getByLabel(/^Reason/).fill('Extra help before the exam');
  await warn.getByRole('button', { name: 'Add anyway' }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  const c = await one<{ n: number }>(
    `select count(*)::int n from public.class_session where title = 'E2E office hours'`,
  );
  expect(c.n).toBe(1);
  const h = await one<{ n: number }>(
    `select count(*)::int n from public.history_event where action = 'Warnings accepted' and note like '%Extra help before the exam%'`,
  );
  expect(h.n).toBe(1);
});

test('"same instructor" off for one class week', async ({ page }) => {
  await openWeek(page, 'Weekend cohort', /Needs instructor|Not asked yet/);
  const dlg = page.getByRole('dialog');
  await dlg.getByText('More options', { exact: true }).click();
  const sw = dlg.getByLabel('The same instructor teaches every class of this week');
  await expect(sw).toBeChecked();
  await sw.click();
  const yes = page.getByRole('button', { name: /yes, continue|split/i });
  await ifShown(yes);
  // The hint before the click also says "each class", so wait for the saved state itself.
  await expect(page.getByText('Each class has its own instructor').first()).toBeVisible();
  await expect
    .poll(
      async () =>
        (
          await one<{ n: number }>(
            `select count(*)::int n from public.module_week where not same_instructor`,
          )
        ).n,
      { timeout: 15_000 },
    )
    .toBeGreaterThan(1);
});

test('settings override at each layer, and reset', async ({ page }) => {
  const label = 'More than 10 days away: ask the next instructor after (hours)';
  const field = async () => {
    await ready(page);
    const f = page.getByLabel(label);
    // The numbers sit in the folded "More options" section that folds again when the
    // page reloads its settings, so open it until the field shows.
    await expect(async () => {
      if (!(await f.isVisible())) {
        const det = page.locator('details', { hasText: 'Show more options' }).first();
        if (!(await det.evaluate((d) => (d as HTMLDetailsElement).open)))
          await det.locator('summary').click();
      }
      await expect(f).toBeVisible({ timeout: 1_000 });
    }).toPass({ timeout: 15_000 });
    return f;
  };
  const scopes: { option: RegExp; source: string; value: string }[] = [
    { option: /^The whole domain/, source: 'From domain settings', value: '50' },
    { option: /^Cohort: Weekend cohort/, source: 'Changed for this cohort', value: '60' },
  ];
  await page.goto('/settings/automation');
  for (const s of scopes) {
    const select = page.getByRole('combobox', { name: 'Settings for' });
    const value = await select
      .locator('option')
      .filter({ hasText: s.option })
      .first()
      .getAttribute('value');
    await select.selectOption(value!);
    const f = await field();
    await f.fill(s.value);
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText(s.source).first()).toBeVisible();
    await expect(f).toHaveValue(s.value);
  }
  const rows = await sql<{ scope: string; value: string }>(
    `select s.scope, s.value::text from public.setting s left join public.cohort c on c.id = s.cohort_id
      where s.key = 'window_long_move_h'
        and coalesce(s.domain_id, c.domain_id) = (select id from public.domain where name = 'Backend')
      order by s.scope`,
  );
  expect(rows.map((r) => r.scope).sort()).toEqual(['Cohort', 'Domain']);
  // Only the domain and its cohorts can be chosen.
  await expect(
    page.getByRole('combobox', { name: 'Settings for' }).locator('option', { hasText: /^Module/ }),
  ).toHaveCount(0);
  // "Use the value above" removes the cohort value; the domain value shows through again.
  await page.getByRole('button', { name: 'Use the value above' }).first().click();
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByText('Changed for this cohort')).toHaveCount(0);
});

test('two people edit the same module: the second is asked to reload', async ({ browser }) => {
  const m = await backendModule('Concurrency');
  const a = await browser.newPage();
  const b = await browser.newPage();
  for (const p of [a, b]) {
    await p.goto(`/setup/modules/${m.id}`);
    await ready(p);
  }
  await a.getByLabel('Name').first().fill('Concurrency A');
  await a.getByRole('button', { name: 'Save changes' }).first().click();
  await expect(a.getByText(/saved/i).first()).toBeVisible();
  await b.getByLabel('Name').first().fill('Concurrency B');
  await b.getByRole('button', { name: 'Save changes' }).first().click();
  await expect(b.getByText(/Someone else saved this after you opened it/)).toBeVisible();
  const now = await backendModule('Concurrency A');
  expect(now.id).toBe(m.id);
  await a.close();
  await b.close();
});

test('owners and the operations team can be reassigned', async ({ page }) => {
  const m = await backendModule('API Design');
  await page.goto(`/setup/modules/${m.id}?tab=owners`);
  await ready(page);
  // A real multi select: search, tick an option (the list stays open), and the chip has a remove button.
  const addOwner = page.getByRole('combobox', { name: 'Add an owner' });
  await addOwner.fill('sandbox esc');
  const ownerList = page.getByRole('listbox', { name: 'Add an owner' });
  await ownerList.getByRole('option', { name: 'Sandbox Escalation' }).click();
  await expect(page.getByRole('button', { name: 'Remove Sandbox Escalation' })).toBeVisible();
  await expect(ownerList.getByRole('option', { name: 'Sandbox Escalation' })).toHaveAttribute(
    'aria-selected',
    'true',
  );
  await addOwner.press('Escape');
  await expect(ownerList).toHaveCount(0);
  await page.goto(`/setup/modules/${m.id}?tab=operations`);
  await ready(page);
  // The keyboard works too: typing makes the first match active, and Enter ticks it.
  const addPerson = page.getByRole('combobox', { name: 'Add a person', exact: true });
  await addPerson.fill('Sandbox Owner');
  await addPerson.press('Enter');
  await expect(page.getByRole('button', { name: 'Remove Sandbox Owner' }).first()).toBeVisible();
  const owners = await sql<{ name: string }>(
    `select t.name from public.module_owner o join public.team_member t on t.id = o.team_member_id
      where o.module_id = $1`,
    [m.id],
  );
  expect(owners.map((o) => o.name)).toContain('Sandbox Escalation');
  const ops = await sql<{ name: string }>(
    `select t.name from public.module_operations o join public.team_member t on t.id = o.team_member_id
      where o.module_id = $1`,
    [m.id],
  );
  expect(ops.map((o) => o.name)).toContain('Sandbox Owner');
});

test("removing a team member's access", async ({ page }) => {
  await page.goto('/setup/team');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Sandbox Escalation' }).click();
  await page.getByRole('button', { name: 'Remove access' }).click();
  await page.getByRole('dialog').last().getByRole('button', { name: 'Remove access' }).click();
  await expect(page.getByText('Access removed')).toBeVisible();
  const t = await one<{ active: boolean; removed: boolean }>(
    `select active, access_removed_at is not null removed from public.team_member where name = 'Sandbox Escalation'`,
  );
  expect(t).toEqual({ active: false, removed: true });
  const h = await one<{ n: number }>(
    `select count(*)::int n from public.history_event where action = 'Access removed'`,
  );
  expect(h.n).toBeGreaterThan(0);
});

test('sign in: a company account gets in, another account is refused', async ({ browser }) => {
  // Google is replaced by an email sign in link here; the database applies the same rule to both.
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  const email = `new.e2e.${Date.now()}@example.com`;
  await page.goto(await signInLink(email));
  await expect(page.getByLabel('Your Discord username')).toBeVisible();
  const made = await one<{ n: number }>(
    `select count(*)::int n from public.team_member where email = $1`,
    [email],
  );
  expect(made.n).toBe(1);
  await ctx.close();
  await expect(signInLink('someone@gmail.com')).rejects.toThrow();
  const refused = await one<{ n: number }>(
    `select count(*)::int n from public.history_event where action = 'Sign in refused' and note like '%someone@gmail.com%'`,
  );
  expect(refused.n).toBeGreaterThan(0);
  expect(EMAIL).toMatch(/@example\.com$/);
});

test('editing a message template, preview and reset', async ({ page }) => {
  await page.goto('/settings/messages');
  await ready(page);
  await page.getByRole('list', { name: 'Messages' }).getByRole('button').first().click();
  const body = page.getByLabel('Message', { exact: false }).last();
  const before = await body.inputValue();
  await body.fill(before + '\nSee you soon.');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByText('Changed').first()).toBeVisible();
  await expect(page.getByText('See you soon.').last()).toBeVisible();
  const saved = await one<{ n: number }>(
    `select count(*)::int n from public.message_template where body like '%See you soon.%'`,
  );
  expect(saved.n).toBe(1);
  await page.getByRole('button', { name: 'Reset to default' }).click();
  await page.getByRole('dialog').last().getByRole('button', { name: 'Reset to default' }).click();
  await expect(body).toHaveValue(before);
});

test('pausing and resuming all messages', async ({ page }) => {
  await page.goto('/');
  await ready(page);
  const mobile = (page.viewportSize()?.width ?? 1280) < 768;
  if (mobile) await page.getByRole('button', { name: 'Open menu' }).click();
  await page.getByRole('button', { name: /your account and theme/i }).click();
  await page.getByRole('menuitem', { name: 'Pause all messages' }).click();
  await page.getByRole('dialog').last().getByRole('button', { name: 'Pause all messages' }).click();
  await expect(page.getByText(/messages are paused/i).first()).toBeVisible();
  expect(
    (
      await one<{ enabled: boolean }>(
        `select outreach_enabled as enabled from public.system_state where id = 1`,
      )
    ).enabled,
  ).toBe(false);
  await page
    .getByRole('button', { name: /resume|turn messages back on/i })
    .first()
    .click();
  const confirm = page.getByRole('dialog').last();
  if (await confirm.isVisible().catch(() => false))
    await confirm.getByRole('button', { name: /turn messages back on|resume/i }).click();
  await expect(page.getByText(/messages are paused/i)).toHaveCount(0);
  expect(
    (
      await one<{ enabled: boolean }>(
        `select outreach_enabled as enabled from public.system_state where id = 1`,
      )
    ).enabled,
  ).toBe(true);
});

test('a practice class passes every stage', async ({ page }) => {
  await page.goto('/settings/testing');
  await ready(page);
  await page.getByRole('button', { name: /run a practice class/i }).click();
  await expect(page.getByText('Every stage worked.')).toBeVisible({ timeout: 60_000 });
  await expect(page.getByLabel('Failed')).toHaveCount(0);
});

test('a US cohort and an India cohort: time zones, badges and the region filter', async ({
  page,
}) => {
  await page.goto('/classes');
  await ready(page);
  await page.getByRole('button', { name: 'Plan classes' }).click();
  const dlg = page.getByRole('dialog');
  await dlg.getByLabel('Cohort').first().selectOption({ label: 'New cohort' });
  await dlg.getByLabel('Name of the new cohort').fill('E2E India');
  await dlg.getByLabel('Region of the new cohort').selectOption('India');
  await dlg
    .getByLabel('Date of the first class')
    .fill(nextDow(new Date(Date.now() + 35 * 864e5), 0));
  await dlg.getByLabel('Number of class weeks').fill('1');
  await dlg.getByRole('button', { name: 'Show the plan' }).click();
  await expect(dlg.getByRole('columnheader', { name: /India time, IST/ })).toBeVisible();
  await dlg.getByRole('button', { name: /^Create 1 class week$/ }).click();
  const anyway = page.getByRole('button', { name: 'Plan anyway' });
  const planned = page.getByText('Planned 1 class week for E2E India');
  await expect(anyway.or(planned).first()).toBeVisible({ timeout: 20_000 });
  if (await anyway.isVisible()) await goAhead(page, 'Plan anyway', 'E2E: these dates on purpose');
  await expect(planned).toBeVisible({ timeout: 20_000 });
  const r = await one<{ cohort: string; classes: string; ist: string }>(
    `select co.region cohort, string_agg(distinct s.region, ',') classes,
            min(to_char(s.starts_at at time zone 'Asia/Kolkata', 'HH24:MI')) ist
       from public.cohort co join public.module_week w on w.cohort_id = co.id
       join public.class_session s on s.module_week_id = w.id
      where co.name = 'E2E India' group by co.region`,
  );
  expect(r).toEqual({ cohort: 'India', classes: 'India', ist: '09:00' });

  // The region filter: India classes show IST only; US classes show PST or PDT and the India time.
  await page.getByRole('combobox', { name: 'Region' }).selectOption('India');
  await ready(page);
  const india = page.locator('tbody tr').filter({ hasText: 'E2E India' }).first();
  await expect(india).toContainText('IST');
  await expect(india).not.toContainText(/PST|PDT/);
  await expect(india.getByText('India', { exact: true })).toBeVisible();
  await page.getByRole('combobox', { name: 'Region' }).selectOption('US');
  await ready(page);
  const us = page.locator('tbody tr').first();
  await expect(us).toContainText(/PST|PDT/);
  await expect(us).toContainText('IST');
  await expect(page.locator('tbody tr').filter({ hasText: 'E2E India' })).toHaveCount(0);
});

test('a time that happens twice asks which one; a time that does not exist is blocked', async ({
  page,
}) => {
  await page.goto('/classes');
  await ready(page);
  await page.getByRole('button', { name: 'Add one class' }).click();
  const dlg = page.getByRole('dialog');
  await dlg.getByLabel('Module').selectOption({ label: 'Database Design' });
  await dlg.getByLabel('Cohort').selectOption({ label: 'Weekend cohort' });
  await expect(dlg.getByText(/^Time in US Pacific \(P[SD]T\)/)).toBeVisible();
  // Sun Mar 14, 2027: the clocks move forward, so 2:30 AM does not exist.
  await dlg.getByLabel('Date').fill('2027-03-14');
  await dlg.getByLabel('Start time').fill('02:30');
  await dlg.getByLabel('End time').fill('03:30');
  await expect(dlg.getByText(/This time does not exist on that day/)).toBeVisible();
  await dlg.getByRole('button', { name: 'Add class' }).click();
  await expect(dlg.getByText('Check the time below.')).toBeVisible();
  // Sun Nov 7, 2027: the clocks move back, so 1:30 AM happens twice.
  await dlg.getByLabel('Date').fill('2027-11-07');
  await dlg.getByLabel('Start time').fill('01:30');
  await dlg.getByLabel('End time').fill('01:45');
  await dlg.getByLabel('Title (optional)').fill('E2E twice');
  await expect(dlg.getByText(/happens twice on this day/)).toBeVisible();
  await dlg.getByLabel(/The second time: 1:30 AM PST/).check();
  await dlg.getByRole('button', { name: 'Add class' }).click();
  await goAhead(page, 'Add anyway', 'E2E: this time on purpose', 8_000);
  await expect(page.getByRole('dialog')).toHaveCount(0);
  const c = await one<{ utc: string }>(
    `select to_char(starts_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI') utc
       from public.class_session where title = 'E2E twice'`,
  );
  expect(c.utc).toBe('2027-11-07 09:30');
});

test('an instructor busy in a US class cannot take an India class at the same moment', async ({
  page,
}) => {
  await sql(
    `insert into public.cohort (domain_id, name, region, status)
     select d.id, 'E2E India', 'India', 'Running' from public.domain d
      where d.name = 'Backend' and not exists (
        select 1 from public.cohort c where c.domain_id = d.id and c.name = 'E2E India')`,
  );
  // A confirmed US weekend class, and the same moment written in India time.
  const b = await one<{ name: string; d: string; s: string; e: string }>(
    `select i.full_name name, to_char(s.starts_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD') d,
            to_char(s.starts_at at time zone 'Asia/Kolkata', 'HH24:MI') s,
            to_char(s.starts_at at time zone 'Asia/Kolkata' + interval '30 minutes', 'HH24:MI') e
       from public.booking bk join public.instructor i on i.id = bk.instructor_id
       join public.module_week w on w.id = bk.module_week_id
       join public.class_session s on s.module_week_id = w.id
       join public.cohort co on co.id = w.cohort_id join public.domain dm on dm.id = w.domain_id
      where bk.status = 'Active' and co.name = 'Weekend cohort' and dm.name = 'Backend'
        and s.status = 'Planned' and s.starts_at > now() and s.region = 'US'
        and to_char(s.starts_at at time zone 'Asia/Kolkata', 'HH24:MI') < '23:30'
      order by s.starts_at limit 1`,
  );
  await page.goto('/classes');
  await ready(page);
  await page.getByRole('button', { name: 'Add one class' }).click();
  const dlg = page.getByRole('dialog');
  await dlg.getByLabel('Module').selectOption({ label: 'Database Design' });
  await dlg.getByLabel('Cohort').selectOption({ label: 'E2E India' });
  await expect(dlg.getByText('Time in India (IST)')).toBeVisible();
  await dlg.getByLabel('Date').fill(b.d);
  await dlg.getByLabel('Start time').fill(b.s);
  await dlg.getByLabel('End time').fill(b.e);
  await dlg.getByLabel('Title (optional)').fill('E2E same moment');
  await dlg.getByRole('button', { name: 'Add class' }).click();
  await goAhead(page, 'Add anyway', 'E2E: this time on purpose', 8_000);
  await expect(page.getByRole('dialog')).toHaveCount(0);

  await page.getByRole('combobox', { name: 'Cohort' }).selectOption({ label: 'E2E India' });
  await page.getByLabel('Search classes').fill('E2E same moment');
  await ready(page);
  await page.locator('tbody tr').first().click();
  const drawer = page.getByRole('dialog');
  await expect(drawer.getByRole('textbox', { name: 'Class title' })).toHaveValue('E2E same moment');
  await ready(page);
  const option = drawer
    .getByRole('combobox', { name: 'Instructor', exact: true })
    .locator('option', { hasText: b.name });
  await expect(option).toContainText(/the same time as this class/);
  await expect(option).toContainText(/PST|PDT/);
  await expect(option).toContainText('IST');
  await expect(option).toBeDisabled();
});
