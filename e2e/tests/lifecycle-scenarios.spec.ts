// Core readiness step 6: create, edit, archive, restore and delete through the app (decisions 254 to 260).
// The rules behind them are covered in depth by database test 230.
import type { Page } from '@playwright/test';
import { a11y, expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
// Every scenario changes the data, so each starts from the same test data.
test.beforeEach(() => loadDemoData());
test.afterAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

async function openDomain(page: Page, name: string) {
  await page.goto('/setup/domains');
  await ready(page);
  await page.getByRole('button', { name, exact: true }).click();
  const d = page.getByRole('dialog', { name });
  await expect(d).toBeVisible();
  return d;
}

/** The delete dialog: what goes with the item, then the typed name when it is asked for. */
async function deleteWithName(page: Page, noun: string, name: string | null) {
  const dlg = page.getByRole('dialog', { name: `Delete this ${noun} permanently?` });
  await expect(dlg).toBeVisible();
  await expect(dlg.getByText('This cannot be undone')).toBeVisible();
  const go = dlg.getByRole('button', { name: 'Delete permanently' });
  if (name) {
    await expect(go).toBeDisabled();
    await dlg.getByLabel(`Type ${name} to confirm`).fill('wrong name');
    await expect(go).toBeDisabled();
    await dlg.getByLabel(`Type ${name} to confirm`).fill(name.toLowerCase());
  }
  // Check the dialog once earlier messages have faded (a message fading in has low contrast for a moment).
  await expect(page.locator('[data-sonner-toast]')).toHaveCount(0, { timeout: 10_000 });
  await a11y(page, `delete ${noun} dialog`);
  await go.click();
  await expect(dlg).toHaveCount(0);
}

test('domain: create one, archive it (hidden from the list and the menu), then restore it', async ({
  page,
}) => {
  await page.goto('/setup/domains');
  await ready(page);
  await page.getByRole('button', { name: 'Create domain' }).first().click();
  await page.getByLabel('Domain name').fill('E2E Data');
  await page.getByRole('dialog').getByRole('button', { name: 'Create domain' }).click();
  await expect(page.getByText('Domain created')).toBeVisible();
  const d = page.getByRole('dialog', { name: 'E2E Data' });
  await d.getByRole('button', { name: 'Archive', exact: true }).click();
  await page
    .getByRole('dialog', { name: 'Archive E2E Data?' })
    .getByRole('button', { name: 'Archive' })
    .click();
  await expect(page.getByText('E2E Data archived')).toBeVisible();
  await d.getByRole('button', { name: 'Close' }).click();
  await expect(page.locator('tbody').getByText('E2E Data')).toHaveCount(0);
  await page.getByLabel(/Show archived domains/).check();
  await expect(page.locator('tbody').getByText('E2E Data')).toBeVisible();
  await page.getByRole('button', { name: 'E2E Data', exact: true }).click();
  await page
    .getByRole('dialog', { name: 'E2E Data' })
    .getByRole('button', { name: 'Restore' })
    .click();
  await expect(page.getByText('E2E Data restored')).toBeVisible();
  const row = await one<{ a: string | null }>(
    `select archived_at a from public.domain where name = 'E2E Data'`,
  );
  expect(row.a).toBeNull();
  expect(
    (
      await one<{ n: number }>(
        `select count(*)::int n from public.history_event where action in ('Domain archived: E2E Data', 'Domain restored: E2E Data')`,
      )
    ).n,
  ).toBe(2);
});

test('cohort: add an India cohort, rename it, archive and restore it, then delete it', async ({
  page,
}) => {
  const d = await openDomain(page, 'Backend');
  await d.getByLabel('New cohort', { exact: true }).fill('E2E India evenings');
  await d.getByLabel('Region of the new cohort').selectOption('India');
  await d.getByRole('button', { name: 'Add cohort' }).click();
  await expect(page.getByText('Cohort E2E India evenings added')).toBeVisible();
  const item = d.locator('li', { hasText: 'E2E India evenings' });
  await expect(item.getByTitle('India time (IST)')).toBeVisible();
  await item.getByRole('button', { name: 'Rename' }).click();
  await d.getByLabel('Cohort name').fill('E2E India nights');
  await d.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Cohort renamed to E2E India nights')).toBeVisible();
  const renamed = d.locator('li', { hasText: 'E2E India nights' });
  await renamed.getByRole('button', { name: 'Archive', exact: true }).click();
  await page
    .getByRole('dialog', { name: 'Archive E2E India nights?' })
    .getByRole('button', { name: 'Archive' })
    .click();
  await expect(renamed.getByText('Archived')).toBeVisible();
  await renamed.getByRole('button', { name: 'Restore' }).click();
  await expect(page.getByText('E2E India nights restored')).toBeVisible();
  // Nothing is linked to it, so no name is asked for.
  await renamed.getByRole('button', { name: 'Delete permanently' }).click();
  await deleteWithName(page, 'cohort', null);
  await expect(page.getByText('E2E India nights deleted')).toBeVisible();
  expect((await sql(`select 1 from public.cohort where name like 'E2E India%'`)).length).toBe(0);
});

test('holiday: add one, edit it, and remove it after a confirmation', async ({ page }) => {
  const d = await openDomain(page, 'Backend');
  await d.getByLabel('Date').last().fill('2027-05-03');
  await d.getByLabel('Name', { exact: true }).last().fill('E2E day off');
  await d.getByRole('button', { name: 'Add holiday' }).click();
  await expect(page.getByText('Holiday added')).toBeVisible();
  const h = d.locator('li', { hasText: 'E2E day off' });
  await h.getByRole('button', { name: 'Edit' }).click();
  await d.getByLabel('Name', { exact: true }).last().fill('E2E long weekend');
  await d.getByRole('button', { name: 'Save holiday' }).click();
  await expect(page.getByText('Holiday saved')).toBeVisible();
  const h2 = d.locator('li', { hasText: 'E2E long weekend' });
  await h2.getByRole('button', { name: 'Remove' }).click();
  await page
    .getByRole('dialog', { name: 'Remove the holiday E2E long weekend?' })
    .getByRole('button', { name: 'Remove' })
    .click();
  await expect(page.getByText('Holiday removed')).toBeVisible();
  expect((await sql(`select 1 from public.holiday where name like 'E2E%'`)).length).toBe(0);
});

test('class time: change one in place; classes already planned stay as they are', async ({
  page,
}) => {
  const m = await one<{ id: string }>(
    `select m.id from public.module m join public.domain d on d.id = m.domain_id where d.name = 'Backend' and m.name = 'API Design'`,
  );
  const before = await one<{ n: number }>(
    `select count(*)::int n from public.class_session c join public.module_week w on w.id = c.module_week_id
      where w.module_id = $1 and to_char(c.starts_at at time zone 'America/Los_Angeles', 'HH24:MI') = '09:00'`,
    [m.id],
  );
  await page.goto(`/setup/modules/${m.id}?tab=times`);
  await ready(page);
  await page.getByRole('button', { name: 'Edit the live class' }).first().click();
  await page.getByLabel('Starts (local time)').fill('10:30');
  await page.getByRole('button', { name: 'Save class time' }).click();
  await expect(page.getByText(/Class time saved/)).toBeVisible();
  const p = await one<{ t: string }>(
    `select to_char(start_time, 'HH24:MI') t from public.class_pattern_item
      where module_id = $1 and cohort_id is null and class_type = 'Live class'`,
    [m.id],
  );
  expect(p.t).toBe('10:30');
  const after = await one<{ n: number }>(
    `select count(*)::int n from public.class_session c join public.module_week w on w.id = c.module_week_id
      where w.module_id = $1 and to_char(c.starts_at at time zone 'America/Los_Angeles', 'HH24:MI') = '09:00'`,
    [m.id],
  );
  expect(after.n).toBe(before.n);
});

test('module: archive it, restore it, then delete it with its classes after typing its name', async ({
  page,
}) => {
  const m = await one<{ id: string }>(
    `select m.id from public.module m join public.domain d on d.id = m.domain_id where d.name = 'Backend' and m.name = 'Concurrency'`,
  );
  await page.goto(`/setup/modules/${m.id}`);
  await ready(page);
  await page.getByRole('button', { name: 'Archive', exact: true }).click();
  await page
    .getByRole('dialog', { name: 'Archive Concurrency?' })
    .getByRole('button', { name: 'Archive' })
    .click();
  await expect(page.getByText('Concurrency archived')).toBeVisible();
  await expect
    .poll(
      async () =>
        (
          await one<{ n: number }>(
            `select count(*)::int n from public.module_week where module_id = $1 and not paused`,
            [m.id],
          )
        ).n,
    )
    .toBe(0);
  await page.getByRole('button', { name: 'Restore' }).click();
  await expect(page.getByText('Concurrency restored')).toBeVisible();
  await page.getByRole('button', { name: 'Delete permanently' }).click();
  await expect(page.getByRole('dialog').getByText(/class weeks.*are deleted/)).toBeVisible();
  await deleteWithName(page, 'module', 'Concurrency');
  await expect(page).toHaveURL(/\/setup\/modules$/);
  expect((await sql(`select 1 from public.module where id = $1`, [m.id])).length).toBe(0);
  expect((await sql(`select 1 from public.module_week where module_id = $1`, [m.id])).length).toBe(
    0,
  );
});

test('instructor: Save and add another, then delete one with linked data after typing the name', async ({
  page,
}) => {
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByRole('button', { name: 'Add instructor' }).first().click();
  const dlg = page.getByRole('dialog', { name: 'Add instructor' });
  await dlg.getByLabel('Full name').fill('E2E First Person');
  await dlg.getByRole('textbox', { name: /^Email/ }).fill('e2e.first@example.org');
  await dlg.getByRole('button', { name: 'Save and add another' }).click();
  await expect(page.getByText('Instructor added')).toBeVisible();
  // The form is empty again for the next person.
  await expect(dlg.getByLabel('Full name')).toHaveValue('');
  await dlg.getByLabel('Full name').fill('E2E Second Person');
  await dlg.getByRole('textbox', { name: /^Email/ }).fill('e2e.second@example.org');
  await dlg.getByRole('button', { name: 'Add instructor' }).click();
  await expect(dlg).toHaveCount(0);
  expect(
    (await sql(`select 1 from public.instructor where full_name like 'E2E % Person'`)).length,
  ).toBe(2);
  // A test instructor in instructor orders: deleting asks for the name and closes up the orders.
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor C' }).first().click();
  await page
    .getByRole('dialog', { name: 'Test Instructor C' })
    .getByRole('button', { name: 'Delete permanently' })
    .click();
  await expect(
    page
      .getByRole('dialog', { name: 'Delete this instructor permanently?' })
      .getByText(/instructor orders/),
  ).toBeVisible();
  await deleteWithName(page, 'instructor', 'Test Instructor C');
  await expect(page.getByText('Test Instructor C deleted')).toBeVisible();
  const gaps = await one<{ n: number }>(
    `select count(*)::int n from (select rank, row_number() over (partition by module_id, cohort_id order by rank) r
       from public.module_ranking) x where rank <> r`,
  );
  expect(gaps.n).toBe(0);
});

test('team: add two people with Save and add another, then delete one', async ({ page }) => {
  await page.goto('/setup/team');
  await ready(page);
  await page.getByRole('button', { name: 'Add team member' }).first().click();
  const dlg = page.getByRole('dialog', { name: 'Add team member' });
  await dlg.getByRole('textbox', { name: /^Name/ }).fill('E2E Colleague One');
  await dlg.getByRole('textbox', { name: /^Email/ }).fill('e2e.one@example.com');
  await dlg.getByRole('button', { name: 'Save and add another' }).click();
  await expect(page.getByText('E2E Colleague One added')).toBeVisible();
  await expect(dlg.getByRole('textbox', { name: /^Name/ })).toHaveValue('');
  await dlg.getByRole('textbox', { name: /^Name/ }).fill('E2E Colleague Two');
  await dlg.getByRole('textbox', { name: /^Email/ }).fill('e2e.two@example.com');
  await dlg.getByRole('button', { name: 'Add team member' }).click();
  await expect(dlg).toHaveCount(0);
  await page.getByRole('button', { name: 'E2E Colleague Two' }).click();
  await page
    .getByRole('dialog', { name: 'E2E Colleague Two' })
    .getByRole('button', { name: 'Delete permanently' })
    .click();
  await deleteWithName(page, 'team member', null);
  await expect(page.getByText('E2E Colleague Two deleted')).toBeVisible();
  expect(
    (await sql(`select name from public.team_member where name like 'E2E Colleague%'`)).map(
      (r) => r.name,
    ),
  ).toEqual(['E2E Colleague One']);
});

/** The class drawer of the first class week of a module in Backend that matches the condition. */
async function openWeek(page: Page, where: string) {
  const w = await one<{ id: string; module: string; week: string }>(
    `select w.id, m.name module, to_char(w.week_start_date, 'Mon FMDD') week
       from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
      where d.name = 'Backend' and ${where} order by w.first_class_at limit 1`,
  );
  await page.goto('/classes');
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${w.module}, week of ${w.week}` })
    .first()
    .click();
  await expect(page.getByRole('dialog')).toBeVisible();
  return w;
}

test('class week: cancel it, then restore it, and the automation can ask again', async ({
  page,
}) => {
  const w = await openWeek(
    page,
    `w.status not in ('Cancelled', 'Completed') and w.first_class_at > now() + interval '20 days'
       and not exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active')`,
  );
  await page.getByRole('dialog').getByRole('button', { name: 'Cancel class week' }).click();
  await page
    .getByRole('dialog', { name: 'Cancel this whole class week?' })
    .getByRole('button', { name: 'Cancel the class week' })
    .click();
  await expect(page.getByText('Class week cancelled')).toBeVisible();
  await page.getByRole('dialog').getByRole('button', { name: 'Restore class week' }).click();
  await expect(page.getByText('Class week restored')).toBeVisible();
  const s = await one<{ s: string }>(`select status s from public.module_week where id = $1`, [
    w.id,
  ]);
  expect(s.s).toBe('Planned');
});

test('class week: deleting one with a confirmed instructor asks for the name and tells them', async ({
  page,
}) => {
  const w = await openWeek(
    page,
    `exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active')`,
  );
  const who = await one<{ id: string }>(
    `select instructor_id id from public.booking where module_week_id = $1 and status = 'Active'`,
    [w.id],
  );
  await page.getByRole('dialog').getByRole('button', { name: 'Delete permanently' }).click();
  await expect(
    page.getByText(/1 confirmed instructor is told their class is cancelled/),
  ).toBeVisible();
  await deleteWithName(page, 'class week', w.module);
  expect((await sql(`select 1 from public.module_week where id = $1`, [w.id])).length).toBe(0);
  const told = await one<{ n: number }>(
    `select count(*)::int n from public.message where template_id = 'M11' and instructor_id = $1`,
    [who.id],
  );
  expect(told.n).toBeGreaterThan(0);
});

test('domain with classes, confirmed instructors and open requests: delete shows what goes and needs the name', async ({
  page,
}) => {
  const before = await one<{ confirmed: number; asking: number }>(
    `select (select count(*)::int from public.booking b join public.module_week w on w.id = b.module_week_id
              join public.domain d on d.id = w.domain_id where d.name = 'Backend' and b.status = 'Active') confirmed,
            (select count(*)::int from public.request r join public.module_week w on w.id = r.module_week_id
              join public.domain d on d.id = w.domain_id where d.name = 'Backend' and r.kind = 'Outreach'
                and r.status in ('Queued', 'Sent', 'Reminded')) asking`,
  );
  expect(before.confirmed).toBeGreaterThan(0);
  expect(before.asking).toBeGreaterThan(0);
  const d = await openDomain(page, 'Backend');
  // The domain's own button is the last one (cohorts above have theirs).
  await d.getByRole('button', { name: 'Delete permanently' }).last().click();
  const dlg = page.getByRole('dialog', { name: 'Delete this domain permanently?' });
  await expect(dlg.getByText(/modules, with their class times/)).toBeVisible();
  await expect(dlg.getByText(/told their class is cancelled/)).toBeVisible();
  await expect(dlg.getByText(/withdrawn, and the instructor is told/)).toBeVisible();
  await deleteWithName(page, 'domain', 'Backend');
  await expect(page.getByText('Backend deleted')).toBeVisible();
  expect((await sql(`select 1 from public.domain where name = 'Backend'`)).length).toBe(0);
  const h = await one<{ n: number }>(
    `select count(*)::int n from public.history_event where action = 'Domain deleted: Backend'`,
  );
  expect(h.n).toBe(1);
  // Nothing points at a missing domain, and the notices still wait to go out.
  const queued = await one<{ n: number }>(
    `select count(*)::int n from public.message where template_id in ('M11', 'M12') and domain_id is null
       and status in ('Scheduled', 'Pending')`,
  );
  expect(queued.n).toBeGreaterThan(0);
});

test('a role: removing someone from the escalation contacts asks first and says it is done', async ({
  page,
}) => {
  const d = await openDomain(page, 'Backend');
  await d.getByRole('button', { name: 'Remove Sandbox Escalation' }).click();
  const confirm = page.getByRole('dialog', {
    name: 'Remove Sandbox Escalation from the escalation contacts?',
  });
  await expect(confirm.getByText(/Activity history keeps a record/)).toBeVisible();
  await confirm.getByRole('button', { name: 'Remove' }).click();
  await expect(
    page.getByText('Sandbox Escalation removed from the escalation contacts'),
  ).toBeVisible();
  const n = await one<{ n: number }>(
    `select count(*)::int n from public.domain_team t join public.domain d on d.id = t.domain_id
      join public.team_member m on m.id = t.team_member_id
     where d.name = 'Backend' and m.name = 'Sandbox Escalation' and t.role = 'Escalation'`,
  );
  expect(n.n).toBe(0);
});
