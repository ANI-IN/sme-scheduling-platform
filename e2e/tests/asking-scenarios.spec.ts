// Release 2 Milestone F (docs/reviews/tests-and-docs.md, TST-10): asking instructors in order, done by a
// person on Instructor requests. The rules behind it are covered in depth by the database tests.
import type { Page } from '@playwright/test';
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
// Each scenario changes who is asked, so each starts from the same fresh data (a skipped scenario
// would hide a gap in the report).
test.beforeEach(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

/** Who is being asked for a class week right now ('' when nobody). */
const askingNow = async (mw: string) =>
  (
    await sql<{ name: string }>(
      `select i.full_name name from public.request r join public.instructor i on i.id = r.instructor_id
        where r.module_week_id = $1 and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')`,
      [mw],
    )
  )[0]?.name ?? '';

/** A class week being asked right now, with someone after them in its instructor order. */
async function weekBeingAsked() {
  return one<{ mw: string; module: string; name: string }>(
    `select r.module_week_id mw, m.name module, i.full_name name
       from public.request r join public.instructor i on i.id = r.instructor_id
       join public.module_week w on w.id = r.module_week_id join public.module m on m.id = w.module_id
      where r.kind = 'Outreach' and r.status in ('Sent', 'Reminded') and w.outreach_mode = 'Sequential'
        and (select count(*) from public.module_ranking k where k.module_id = w.module_id) >= 3
      order by w.first_class_at limit 1`,
  );
}

/** The row of that class week on Instructor requests (module name and the person being asked). */
async function rowOf(page: Page, module: string, name: string) {
  await page.goto('/requests');
  await ready(page);
  const row = page
    .locator('tbody tr')
    .filter({ hasText: module })
    .filter({ hasText: name })
    .first();
  await expect(row).toBeVisible();
  return row;
}

test('ask the next instructor: the person being asked is skipped politely', async ({ page }) => {
  const w = await weekBeingAsked();
  const row = await rowOf(page, w.module, w.name);
  await row.getByRole('button', { name: 'Ask the next instructor' }).click();
  await expect(page.getByRole('dialog')).toContainText(`Skip ${w.name}?`);
  await page.getByRole('dialog').getByRole('button', { name: 'Ask the next instructor' }).click();
  await expect(page.getByText('Asked the next instructor')).toBeVisible();
  // Someone else is asked now, and the row shows them.
  await expect.poll(() => askingNow(w.mw), { timeout: 15_000 }).not.toBe(w.name);
  const next = await askingNow(w.mw);
  expect(next).not.toBe('');
  await expect(
    page.locator('tbody tr').filter({ hasText: w.module }).filter({ hasText: next }).first(),
  ).toBeVisible();
  // The skipped person is told their request is withdrawn (M12), once.
  const told = await one<{ n: number }>(
    `select count(*)::int n from public.message m join public.instructor i on i.id = m.instructor_id
      where m.module_week_id = $1 and i.full_name = $2 and m.template_id = 'M12'
        and coalesce(m.unique_key, '') not like '%:copy' and coalesce(m.unique_key, '') not like '%:DM%'
        and m.channel = 'Email'`,
    [w.mw, w.name],
  );
  expect(told.n).toBe(1);
});

test('choose who to ask: two people in a custom order', async ({ page }) => {
  const w = await weekBeingAsked();
  // Two instructors who may be asked for this week and are not being asked now.
  const pick = await sql<{ id: string; name: string }>(
    `select i.id, i.full_name name from public.module_ranking k join public.instructor i on i.id = k.instructor_id
      where k.module_id = (select module_id from public.module_week where id = $1)
        and i.full_name <> $2 and i.status = 'Active'
        and not exists (select 1 from public.request r where r.module_week_id = $1 and r.instructor_id = i.id)
      order by k.rank desc limit 2`,
    [w.mw, w.name],
  );
  expect(pick.length, 'two people left to ask in the starting data').toBe(2);
  const [second, first] = pick as [{ id: string; name: string }, { id: string; name: string }];
  const row = await rowOf(page, w.module, w.name);
  await row.getByRole('button', { name: 'More options' }).click();
  await page.getByRole('menuitem', { name: 'Change the order for this class week' }).click();
  const dlg = page.getByRole('dialog', { name: 'Choose who to ask' });
  await expect(dlg).toBeVisible();
  await ready(page);
  // Tick the person to ask first, then the second: the order below follows the ticks.
  await dlg.getByRole('checkbox', { name: new RegExp(first.name) }).check();
  await dlg.getByRole('checkbox', { name: new RegExp(second.name) }).check();
  const order = dlg.locator('ol li');
  await expect(order.nth(0)).toContainText(first.name);
  await expect(order.nth(1)).toContainText(second.name);
  await dlg.getByRole('button', { name: 'Start asking' }).click();
  // Someone is being asked right now: withdraw that request and start the new list.
  await page.getByRole('button', { name: 'Withdraw and start the new list' }).click();
  await expect.poll(() => askingNow(w.mw), { timeout: 15_000 }).toBe(first.name);
  const list = await sql<{ id: string }>(
    `select instructor_id id from public.manual_queue_item where module_week_id = $1 order by position`,
    [w.mw],
  );
  expect(list.map((x) => x.id).slice(0, 2)).toEqual([first.id, second.id]);
  const mode = await one<{ m: string }>(
    `select outreach_mode m from public.module_week where id = $1`,
    [w.mw],
  );
  expect(mode.m).toBe('Manual');
  // The row says the week now follows a chosen list.
  await expect(
    page.locator('tbody tr').filter({ hasText: w.module }).filter({ hasText: first.name }).first(),
  ).toContainText('Chosen list');
});

test('start asking now: a class week not started yet asks the first person in its order', async ({
  page,
}) => {
  const w = await sql<{ mw: string; module: string; first: string }>(
    `select w.id mw, m.name module,
            (select i.full_name from public.module_ranking k join public.instructor i on i.id = k.instructor_id
              where k.module_id = w.module_id and i.status = 'Active' order by k.rank limit 1) first
       from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
      where d.name = 'Backend' and w.status in ('Planned', 'Ready') and not w.paused
        and w.first_class_at > now() + interval '3 days'
        and not exists (select 1 from public.request r where r.module_week_id = w.id)
      order by w.first_class_at limit 1`,
  );
  expect(w.length, 'a class week not asked yet in the starting data').toBe(1);
  const x = w[0]!;
  await page.goto('/requests');
  await ready(page);
  const row = page
    .locator('tbody tr')
    .filter({ hasText: x.module })
    .filter({ hasText: /Not started yet|Ready to ask/ })
    .first();
  await row.getByRole('button', { name: 'Start asking now' }).click();
  await expect.poll(() => askingNow(x.mw), { timeout: 15_000 }).not.toBe('');
  expect(await askingNow(x.mw)).toBe(x.first);
});
