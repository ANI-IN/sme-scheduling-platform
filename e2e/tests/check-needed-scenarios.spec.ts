// Decision 341: a message the automation took 15 minutes ago without saying whether it was sent is never sent again
// by itself. It shows as "Check needed" with a task, and the team chooses "It arrived, mark as sent" or "Send again".
// The rule itself (15 minutes, no copy, the alert, a late answer) is covered by pgTAP 730.
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';
import type { Page } from '@playwright/test';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

/** A request message to Test Instructor A that the automation took 20 minutes ago and never answered for. */
async function stuckMessage(key: string) {
  const m = await one<{ id: string; module: string; week: string }>(
    `insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id,
            module_week_id, recipient_label, body_text, attempts, claimed_at, is_test)
     select d.id, 'Instructor', 'M1', 'Discord', $1, 'Sending', i.id, w.id, i.full_name, 'Can you teach?', 1,
            now() - interval '20 minutes', private.is_test_domain(d.id)
       from public.domain d
       join public.module_week w on w.domain_id = d.id
       join public.instructor i on i.full_name = 'Test Instructor A'
      where d.name = 'Backend' and w.status not in ('Cancelled', 'Completed') and w.first_class_at > now()
      order by w.first_class_at limit 1
     returning id, (select m.name from public.module m join public.module_week x on x.module_id = m.id
                     where x.id = module_week_id) module,
               (select to_char(x.week_start_date, 'Mon FMDD') from public.module_week x where x.id = module_week_id) week`,
    [key],
  );
  // What the automation's next run does with it (the run itself is covered by pgTAP 730).
  await sql(`select private.mark_check_needed($1)`, [m.id]);
  return m;
}

const status = async (id: string) =>
  (await one<{ status: string }>(`select status from public.message where id = $1`, [id])).status;

async function taskRow(page: Page) {
  await page.goto('/');
  await ready(page);
  return page.locator('li').filter({ hasText: 'Check whether "' }).first();
}

test('Check needed: a task says what to check, and It arrived marks the message as sent', async ({
  page,
}) => {
  const m = await stuckMessage('e2e-check-arrived');
  expect(await status(m.id)).toBe('CheckNeeded');
  const row = await taskRow(page);
  await expect(row).toContainText('Check if a message arrived');
  await expect(row).toContainText('reached Test Instructor A');
  await expect(row).toContainText('not sent again by itself');
  await row.getByRole('button', { name: 'It arrived, mark as sent' }).click();
  await expect(page.getByText('Marked as sent')).toBeVisible();
  expect(await status(m.id)).toBe('Sent');
  const copies = await one<{ n: number }>(
    `select count(*)::int n from public.message where unique_key like 'e2e-check-arrived%'`,
  );
  expect(copies.n).toBe(1);
  const h = await one<{ n: number }>(
    `select count(*)::int n from public.history_event where entity_id = $1 and action like 'Marked as arrived:%'`,
    [m.id],
  );
  expect(h.n).toBe(1);
});

test('Check needed in the class week panel: the message shows it, and Send again sends one copy', async ({
  page,
}) => {
  const m = await stuckMessage('e2e-check-again');
  await page.goto('/classes');
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${m.module}, week of ${m.week}` })
    .first()
    .click();
  const dlg = page.getByRole('dialog');
  await expect(dlg).toBeVisible();
  await dlg.getByText(/^Messages \(\d+\)$/).click();
  const item = dlg.locator('li').filter({ hasText: 'Not known whether it arrived' }).first();
  await expect(item.getByText('Check needed', { exact: true })).toBeVisible();
  await item.getByRole('button', { name: 'Send again' }).click();
  await expect(page.getByText('Sent again')).toBeVisible();
  expect(await status(m.id)).toBe('Failed');
  const again = await sql<{ status: string }>(
    `select status from public.message where unique_key like 'e2e-check-again:resend:%'`,
  );
  expect(again.map((x) => x.status)).toHaveLength(1);
  expect(['Pending', 'Scheduled', 'Sending', 'Sent']).toContain(again[0]!.status);
  const task = await one<{ status: string }>(
    `select status from public.attention_item where dedupe_key = 'msgcheck:' || $1`,
    [m.id],
  );
  expect(task.status).toBe('Done');
});
