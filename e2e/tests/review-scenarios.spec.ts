// Review batch 6 (decision 349): the screen side of R9, R10, R11, R23, R37, R40 and R41. The rules themselves are in
// the unit tests and pgTAP 820.
import { expect, loadDemoData, noDashes, ready, sql, test } from './fixtures.ts';
import type { Page } from '@playwright/test';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;
const statusOf = async (name: string) =>
  (await one<{ s: string }>(`select status s from public.domain where name = $1`, [name])).s;

async function openDomain(page: Page, name: string) {
  await page.goto('/setup/domains');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: name }).first().click();
  await ready(page);
  return page.getByRole('dialog').first();
}

/** A Backend class week with a confirmed instructor and a message that reached them. */
async function bookedWeek() {
  return one<{ module: string; week: string; instructor: string; id: string }>(
    `select m.name module, to_char(w.week_start_date, 'Mon FMDD') week, i.full_name instructor, w.id
       from public.module_week w join public.domain d on d.id = w.domain_id and d.name = 'Backend'
       join public.module m on m.id = w.module_id
       join public.booking b on b.module_week_id = w.id and b.status = 'Active'
       join public.instructor i on i.id = b.instructor_id
      where w.first_class_at > now() and exists (select 1 from public.message x where x.module_week_id = w.id
             and x.instructor_id = i.id and x.audience = 'Instructor' and x.template_id not in ('M3', 'M11', 'M12', 'M16'))
      order by w.first_class_at limit 1`,
  );
}

async function openWeekFromClasses(page: Page, module: string, week: string) {
  await page.goto('/classes');
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${module}, week of ${week}` })
    .first()
    .click();
  const dlg = page.getByRole('dialog', { name: new RegExp(`^${module}: week of`) });
  await expect(dlg).toBeVisible();
  await ready(page);
  return dlg;
}

test('R9: arrow keys change no status, and Draft asks first, naming what happens', async ({
  page,
}) => {
  const before = await statusOf('Backend');
  const dlg = await openDomain(page, 'Backend');
  const status = dlg.getByRole('combobox', { name: 'Status' });
  await status.focus();
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowUp');
  await page.keyboard.press('ArrowUp');
  await expect(status).toHaveValue(before);
  await status.selectOption('Draft');
  const ask = page.getByRole('dialog', { name: 'Move Backend back to Draft?' });
  await expect(ask).toBeVisible();
  await expect(ask).toContainText(/open requests? (is|are) withdrawn/);
  await noDashes(page, 'draft confirmation');
  await ask.getByRole('button', { name: 'Go back' }).click();
  await expect.poll(() => statusOf('Backend')).toBe(before);
});

test('R9: turning on testing for a live domain asks first', async ({ page }) => {
  await sql(`update public.domain set status = 'Live', version = version where name = 'Backend'`);
  await page.goto('/settings/testing');
  await ready(page);
  await page.getByRole('button', { name: 'Turn on testing' }).click();
  const ask = page.getByRole('dialog', { name: 'Turn on testing for Backend?' });
  await expect(ask).toContainText('testing channel');
  await ask.getByRole('button', { name: 'Go back' }).click();
  await expect.poll(() => statusOf('Backend')).toBe('Live');
  loadDemoData();
});

test('R10: switching domains with an unsaved setting asks first', async ({ page }) => {
  await page.goto('/settings/automation');
  await ready(page);
  const field = page.locator('main input[type="number"]').first();
  const old = await field.inputValue();
  await field.fill(String(Number(old) + 1));
  let asked = '';
  page.once('dialog', (d) => {
    asked = d.message();
    void d.dismiss();
  });
  await page.getByRole('button', { name: /choose a domain/i }).click();
  await page.getByRole('menuitem', { name: /Fullstack/ }).click();
  await expect.poll(() => asked).toContain('unsaved changes');
  await expect(field).toHaveValue(String(Number(old) + 1));
});

test('R11: Send last message again asks first, then sends one copy', async ({ page }) => {
  const w = await bookedWeek();
  const count = async () =>
    (
      await one<{ n: number }>(
        `select count(*)::int n from public.message where module_week_id = $1 and unique_key like '%:resend:%'`,
        [w.id],
      )
    ).n;
  const dlg = await openWeekFromClasses(page, w.module, w.week);
  await dlg.getByText('More options', { exact: true }).click();
  await dlg.getByRole('button', { name: 'Send last message again' }).click();
  const ask = page.getByRole('dialog', { name: new RegExp(`to ${w.instructor} again\\?$`) });
  await ask.getByRole('button', { name: 'Go back' }).click();
  expect(await count()).toBe(0);
  await dlg.getByRole('button', { name: 'Send last message again' }).click();
  await ask.getByRole('button', { name: 'Send again' }).click();
  await expect(page.getByText('Message sent again')).toBeVisible();
  expect(await count()).toBe(1);
});

test('R23: a class someone else saves keeps what you are typing', async ({ page }) => {
  const w = await bookedWeek();
  const dlg = await openWeekFromClasses(page, w.module, w.week);
  const notes = dlg.getByRole('textbox', { name: 'Notes' }).first();
  await notes.fill('E2E typed notes');
  await sql(
    `update public.class_session set title = title || ' (moved room)', version = version
      where id = (select id from public.class_session where module_week_id = $1 and status = 'Planned' order by starts_at limit 1)`,
    [w.id],
  );
  await expect(dlg.getByText('Someone else saved this class while you were typing.')).toBeVisible({
    timeout: 15_000,
  });
  await expect(notes).toHaveValue('E2E typed notes');
});

test('R37: Contact instructor says what was really queued', async ({ page }) => {
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor A' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByLabel('Message to Test Instructor A').fill('E2E hello');
  await dlg.getByRole('button', { name: 'Send message' }).click();
  await expect(page.getByText(/(Message sent to Test Instructor A by|was not sent)/)).toBeVisible();
});

test('R40: every class week checkbox says which week it picks', async ({ page }) => {
  await page.goto('/classes');
  await ready(page);
  const labels = await page
    .locator('tbody input[type="checkbox"]')
    .evaluateAll((xs) => xs.map((x) => x.getAttribute('aria-label') ?? ''));
  expect(labels.length).toBeGreaterThan(1);
  expect(new Set(labels).size).toBe(labels.length);
});

test('R41: the sign in page shows no text taken from the address', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  await page.goto('/login#error_description=Call+555+0100+to+unlock+your+account');
  await expect(page.getByText('Sign in did not work.', { exact: false })).toBeVisible();
  await expect(page.getByText('555 0100')).toHaveCount(0);
  await ctx.close();
});

test('R34: pressing Assign twice quickly assigns once', async ({ page }) => {
  await loadDemoData();
  const w = await one<{ module: string; week: string; instr: string }>(
    `select m.name module, to_char(mw.week_start_date, 'Mon FMDD') week, i.id instr
       from public.module_week mw join public.module m on m.id = mw.module_id
       join public.domain d on d.id = mw.domain_id and d.name = 'Backend'
       join public.module_ranking k on k.module_id = mw.module_id join public.instructor i on i.id = k.instructor_id
      where not exists (select 1 from public.booking b where b.module_week_id = mw.id and b.status = 'Active')
        and mw.status not in ('Cancelled', 'Completed') and mw.first_class_at > now() + interval '3 days'
        and private.eligibility(i.id, mw.id) is null
      order by mw.first_class_at, k.rank desc limit 1`,
  );
  let calls = 0;
  page.on('request', (r) => {
    if (r.url().includes('/rpc/assign_manually')) calls += 1;
  });
  const dlg = await openWeekFromClasses(page, w.module, w.week);
  await dlg.getByLabel('Instructor').selectOption(w.instr);
  await dlg.getByRole('button', { name: 'Assign and confirm instructor' }).dblclick();
  await expect.poll(() => calls).toBeGreaterThan(0);
  await page.waitForTimeout(1500);
  expect(calls).toBe(1);
});

test('R35: an edit that cannot be saved as the form closes is said out loud', async ({
  page,
  problems,
}) => {
  problems.allow.push(/HTTP 400: PATCH .*\/instructor/, /Failed to load resource/);
  await page.route('**/rest/v1/instructor?*', (route) =>
    route.request().method() === 'PATCH'
      ? route.fulfill({
          status: 400,
          contentType: 'application/json',
          body: JSON.stringify({ message: 'E2E: not saved' }),
        })
      : route.continue(),
  );
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor A' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByLabel('Notes').fill('E2E note typed just before closing');
  await page.keyboard.press('Escape');
  await expect(page.getByText('Your last change was not saved. E2E: not saved')).toBeVisible();
});
