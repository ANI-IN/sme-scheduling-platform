// Release 2 Milestone F: screen scenarios for the workflows that only had database tests: answers,
// confirmation, replacing an instructor, reminders and help requests. The rules behind them are
// covered in depth by supabase/tests/database; here a person does each one in the app.
import type { Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noSidewaysScroll, ready, sql, test } from './fixtures.ts';

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

test('an instructor answers Yes: the answer page, then a confirmed class on screen', async ({
  page,
}) => {
  // A class week where someone is being asked, and the link of their Yes button.
  const r = await one<{ mw: string; token: string; name: string; module: string; week: string }>(
    `select r.module_week_id mw, l.token, i.full_name name, m.name module,
            to_char(w.week_start_date, 'Mon FMDD') week
       from public.request r join public.response_link l on l.request_id = r.id
       join public.instructor i on i.id = r.instructor_id
       join public.module_week w on w.id = r.module_week_id join public.module m on m.id = w.module_id
      where r.kind = 'Outreach' and r.status in ('Sent', 'Reminded') and l.answer = 'Yes'
      order by r.created_at limit 1`,
  );
  // The page the instructor opens from the Yes button (served by n8n from response_page), on a phone.
  const html = await one<{ h: string }>(`select public.response_page($1)::text h`, [r.token]);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.setContent(html.h);
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(page.getByRole('button').first()).toBeVisible();
  await a11y(page, 'the answer page');
  await noSidewaysScroll(page, 'the answer page');
  const base = await one<{ u: string }>(
    `select response_base_url u from public.app_config where id = 1`,
  );
  await page.route(
    (u) => u.href.startsWith(base.u),
    async (route) => {
      const form = Object.fromEntries(new URLSearchParams(route.request().postData() ?? ''));
      const out = await one<{ h: string }>(`select public.submit_response_page($1, $2)::text h`, [
        form.t ?? '',
        JSON.stringify(form),
      ]);
      await route.fulfill({ status: 200, contentType: 'text/html', body: out.h });
    },
  );
  await page.getByRole('button').first().click();
  await expect(page.getByText(/You.re confirmed/).first()).toBeVisible();
  await a11y(page, 'the page after pressing Yes');
  await noSidewaysScroll(page, 'the page after pressing Yes');
  await page.unrouteAll();
  await page.setViewportSize({ width: 1440, height: 900 });
  const again = await one<{ out: { result: string } }>(`select public.record_response($1) out`, [
    r.token,
  ]);
  expect(again.out.result).toBe('already_recorded');
  // That exact class week shows the instructor as confirmed.
  await page.goto('/classes');
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${r.module}, week of ${r.week}` })
    .first()
    .click();
  const dlg = page.getByRole('dialog');
  await expect(dlg.getByText(`Confirmed: ${r.name}`)).toBeVisible();
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
  // One confirmed class week with someone left to ask after the confirmed instructor.
  const w = await one<{ id: string; instr: string; name: string; module: string; week: string }>(
    `select b.module_week_id id, b.instructor_id instr, i.full_name name, m.name module,
            to_char(mw.week_start_date, 'Mon FMDD') week
       from public.booking b join public.module_week mw on mw.id = b.module_week_id
       join public.module m on m.id = mw.module_id join public.instructor i on i.id = b.instructor_id
      where b.status = 'Active' and mw.first_class_at > now() + interval '3 days'
        and exists (select 1 from public.module_ranking k where k.module_id = mw.module_id and k.instructor_id <> b.instructor_id)
        -- Not the week with the help request: releasing it closes the request a later scenario answers. Which week
        -- comes first depends on today's date.
        and not exists (select 1 from public.help_request h where h.module_week_id = mw.id)
      order by mw.first_class_at limit 1`,
  );
  await page.goto('/classes');
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${w.module}, week of ${w.week}` })
    .first()
    .click();
  const dlg = page.getByRole('dialog');
  await expect(dlg.getByText(`Confirmed: ${w.name}`)).toBeVisible();
  await dlg.getByRole('button', { name: 'Release instructor' }).click();
  await page.getByRole('button', { name: 'Release and find a replacement' }).click();
  await expect(page.getByText('Instructor released')).toBeVisible();
  // The released instructor is thanked, and the booking says the team released them.
  const rel = await one<{ reason: string; notes: number }>(
    `select b.release_reason reason,
            (select count(*)::int from public.message m where m.module_week_id = b.module_week_id
              and m.instructor_id = b.instructor_id and m.template_id = 'M16') notes
       from public.booking b where b.module_week_id = $1 and b.instructor_id = $2 and b.status = 'Released'`,
    [w.id, w.instr],
  );
  expect(rel.notes).toBeGreaterThan(0);
  expect(rel.reason).toBe('OpsReleased');
  // Someone else is asked for this class week, and the drawer says who.
  await expect
    .poll(
      async () =>
        (
          await sql<{ name: string }>(
            `select i.full_name name from public.request r join public.instructor i on i.id = r.instructor_id
              where r.module_week_id = $1 and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')`,
            [w.id],
          )
        )[0]?.name ?? '',
      { timeout: 15_000 },
    )
    .not.toBe('');
  const next = await one<{ name: string }>(
    `select i.full_name name from public.request r join public.instructor i on i.id = r.instructor_id
      where r.module_week_id = $1 and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')`,
    [w.id],
  );
  expect(next.name).not.toBe(w.name);
  await expect(dlg.getByText(`Waiting for an answer from ${next.name}.`)).toBeVisible();
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
  // A switch saves as soon as it changes: there is no Save changes bar for it.
  await sw.click();
  await expect.poll(value).toBe(String(!wasOn));
  await expect(page.getByRole('button', { name: 'Save changes' })).toHaveCount(0);
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  // Back on: the switch shows the saved value after a reload.
  await sw.click();
  await expect.poll(value).not.toBe(String(!wasOn));
  await expect(page.getByRole('button', { name: 'Save changes' })).toHaveCount(0);
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

test('assigning by hand: someone who cannot teach those dates cannot be chosen, and the reason shows', async ({
  page,
}) => {
  // A class week still looking for an instructor, and someone in its instructor order who says they
  // cannot teach that week.
  const w = await one<{ id: string; module: string; week: string; name: string; instr: string }>(
    `select mw.id, m.name module, to_char(mw.week_start_date, 'Mon FMDD') week, i.full_name name, i.id instr
       from public.module_week mw join public.module m on m.id = mw.module_id
       join public.domain d on d.id = mw.domain_id
       join public.module_ranking k on k.module_id = mw.module_id join public.instructor i on i.id = k.instructor_id
      where d.name = 'Backend' and not exists (select 1 from public.booking b where b.module_week_id = mw.id and b.status = 'Active')
        and mw.status not in ('Cancelled', 'Completed') and mw.first_class_at > now() + interval '3 days'
        and not exists (select 1 from public.request r where r.module_week_id = mw.id and r.instructor_id = i.id
                         and r.status in ('Queued', 'Sent', 'Reminded'))
      order by mw.first_class_at, k.rank desc limit 1`,
  );
  await sql(
    `insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason)
     select $1, (w.first_class_at at time zone 'America/Los_Angeles')::date - 1,
            (w.first_class_at at time zone 'America/Los_Angeles')::date + 7, 'E2E away'
       from public.module_week w where w.id = $2`,
    [w.instr, w.id],
  );
  await page.goto('/classes');
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${w.module}, week of ${w.week}` })
    .first()
    .click();
  const dlg = page.getByRole('dialog');
  const option = dlg.getByLabel('Instructor').locator('option', { hasText: w.name });
  await expect(option).toContainText('Unavailable');
  await expect(option).toBeDisabled();
});

test('Home: on it, assign to someone, and mark done with a note', async ({ page }) => {
  // An open task of the domain being shown, with a title the screen shows as it is.
  const t = await one<{ id: string; title: string }>(
    `insert into public.attention_item (domain_id, type, severity, status, title, detail)
     select d.id, 'Other', 'Normal', 'Open', 'E2E call the venue about the projector', 'Made by a test'
       from public.domain d where d.name = 'Backend'
     returning id, title`,
  );
  const me = await one<{ id: string; name: string }>(
    `select id, name from public.team_member where active and access_removed_at is null order by name limit 1`,
  );
  await page.goto('/');
  await ready(page);
  const item = () => page.locator('li', { hasText: t.title }).first();
  await item().getByRole('button', { name: /on it/ }).click();
  await expect(page.getByText('Reminders paused for 24 hours')).toBeVisible();
  await expect
    .poll(
      async () =>
        (
          await one<{ s: string }>(`select status s from public.attention_item where id = $1`, [
            t.id,
          ])
        ).s,
    )
    .not.toBe('Open');
  await item().getByLabel('Assign to a team member').selectOption(me.id);
  await expect(page.getByText('Assigned', { exact: true })).toBeVisible();
  await expect
    .poll(
      async () =>
        (
          await one<{ a: string }>(
            `select assigned_to a from public.attention_item where id = $1`,
            [t.id],
          )
        ).a,
    )
    .toBe(me.id);
  await item().getByRole('button', { name: 'Mark done' }).click();
  const dlg = page.getByRole('dialog', { name: 'Mark done' });
  await dlg.getByLabel('Note (optional)').fill('E2E handled on a call');
  await dlg.getByRole('button', { name: 'Mark done' }).click();
  await expect(page.getByText('Marked done')).toBeVisible();
  await expect(dlg).toHaveCount(0);
  const done = await one<{ s: string; note: string }>(
    `select status s, done_note note from public.attention_item where id = $1`,
    [t.id],
  );
  expect(done).toEqual({ s: 'Done', note: 'E2E handled on a call' });
});
