// Release 2 Milestone F: screen scenarios for the workflows that only had database tests: answers,
// confirmation, replacing an instructor, reminders and help requests. The rules behind them are
// covered in depth by supabase/tests/database; here a person does each one in the app.
import type { Page } from '@playwright/test';
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
test.beforeAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

/** Open the class drawer of the first Backend class week with this status text. */
async function openWeek(page: Page, has: RegExp) {
  await page.goto('/classes');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: has }).first().click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await ready(page);
  return page.getByRole('dialog');
}

test('an instructor answers Yes: the request turns into a confirmed class on screen', async ({
  page,
}) => {
  // A class week where someone is being asked, and the link of their Yes button.
  const r = await one<{ mw: string; token: string; name: string }>(
    `select r.module_week_id mw, l.token, i.full_name name
       from public.request r join public.response_link l on l.request_id = r.id
       join public.instructor i on i.id = r.instructor_id
      where r.kind = 'Outreach' and r.status in ('Sent', 'Reminded') and l.answer = 'Yes'
      order by r.created_at limit 1`,
  );
  await page.goto('/requests');
  await ready(page);
  await expect(page.getByText(r.name).first()).toBeVisible();
  // The instructor presses Yes (the automation passes the click to the database).
  const res = await one<{ out: { result: string } }>(`select public.record_response($1) out`, [
    r.token,
  ]);
  expect(res.out.result).toBeTruthy();
  const again = await one<{ out: { result: string } }>(`select public.record_response($1) out`, [
    r.token,
  ]);
  expect(JSON.stringify(again.out)).toMatch(/already/i);
  await page.reload();
  await ready(page);
  await page.getByRole('button', { name: /^Confirmed/ }).click();
  await expect(page.getByText(r.name).first()).toBeVisible();
  const b = await one<{ n: number }>(
    `select count(*)::int n from public.booking where module_week_id = $1 and status = 'Active'`,
    [r.mw],
  );
  expect(b.n).toBe(1);
});

test('a confirmed class: tick a checklist task in the class drawer', async ({ page }) => {
  const dlg = await openWeek(page, /Confirmed/);
  // The first checklist task of the first class (not the class outcome boxes above it).
  const first = dlg.getByRole('checkbox', { name: 'Zoom link added' }).first();
  await expect(first).toBeVisible();
  const doneCount = async () =>
    (await one<{ n: number }>(`select count(*)::int n from public.checklist_item where done`)).n;
  const before = await doneCount();
  const was = await first.isChecked();
  await first.click();
  await expect(first).toBeChecked({ checked: !was });
  // The tick is saved: one more (or one fewer) task is done.
  await expect.poll(doneCount).toBe(before + (was ? -1 : 1));
});

test('replacing an instructor: release from the class drawer, the next one is asked', async ({
  page,
}) => {
  const dlg = await openWeek(page, /Confirmed/);
  const mw = await one<{ id: string; instr: string }>(
    `select b.module_week_id id, b.instructor_id instr from public.booking b
      where b.status = 'Active' order by b.confirmed_at desc limit 1`,
  );
  await dlg.getByRole('button', { name: 'Release instructor' }).click();
  await page.getByRole('button', { name: 'Release and find a replacement' }).click();
  await expect(page.getByText('Instructor released')).toBeVisible();
  const rel = await one<{ n: number; notes: number }>(
    `select count(*)::int n,
            (select count(*)::int from public.message m join public.booking b2 on b2.instructor_id = m.instructor_id
              where b2.status = 'Released' and m.template_id = 'M16' and m.module_week_id = b2.module_week_id) notes
       from public.booking where status = 'Released'`,
  );
  expect(rel.n).toBeGreaterThan(0);
  expect(rel.notes).toBeGreaterThan(0);
  expect(mw.instr).toBeTruthy();
  await expect(dlg.getByText(/No instructor confirmed yet|Asking .* now/)).toBeVisible();
});

test('reminders: the daily summary is switched off for the domain and back on', async ({
  page,
}) => {
  await page.goto('/settings/automation');
  await ready(page);
  const sw = page.getByRole('switch', { name: 'Send each team member a daily summary' });
  await expect(sw).toBeVisible();
  const wasOn = (await sw.getAttribute('aria-checked')) === 'true';
  const value = async () => {
    const rows = await sql<{ v: unknown }>(
      `select s.value v from public.setting s join public.domain d on d.id = s.domain_id
        where d.name = 'Backend' and s.key = 'daily_summary' and s.cohort_id is null
          and s.module_id is null and s.module_week_id is null`,
    );
    return rows.length ? String(rows[0]!.v) : 'default';
  };
  await sw.click();
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect.poll(value).toBe(String(!wasOn));
  // Back on: the switch shows the saved value after a reload.
  await sw.click();
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect.poll(value).not.toBe(String(!wasOn));
  await page.reload();
  await ready(page);
  await expect(sw).toHaveAttribute('aria-checked', String(wasOn));
});

test('a help request: the team replies and the instructor is answered', async ({ page }) => {
  await page.goto('/');
  await ready(page);
  await page.getByRole('button', { name: 'Open help request', exact: true }).first().click();
  const panel = page.getByRole('dialog');
  await ready(page);
  const reply = panel.getByLabel(/Reply to the instructor/);
  await reply.fill('The slides are in the module folder.');
  await panel.getByRole('button', { name: 'Send reply' }).click();
  await expect(page.getByText('Reply sent')).toBeVisible();
  const h = await one<{ n: number }>(
    `select count(*)::int n from public.message where template_id = 'M14' and body_text like '%slides are in the module folder%'`,
  );
  expect(h.n).toBeGreaterThan(0);
});
