// The owner's live testing of 23 November 2026, the High findings (decision 331), on the Sandbox
// starting data. Nothing reaches Discord here: the database parts are covered by pgTAP 630, and these
// scenarios check what the Operations team sees.
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;

test('a domain status that is not ready says what is missing, with a way to fix each, and does not change', async ({
  page,
}) => {
  await sql(
    `update public.domain set discord_server_id = null, discord_status = 'NotSet' where name = 'Fullstack'`,
  );
  const before = await one<{ s: string }>(
    `select status s from public.domain where name = 'Fullstack'`,
  );
  await page.goto('/setup/domains');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Fullstack' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByRole('combobox', { name: 'Status' }).selectOption('Live');
  await expect(dlg.getByText('Fullstack cannot be live yet. It needs:')).toBeVisible();
  await expect(dlg.getByText("Choose the domain's Discord server.")).toBeVisible();
  await expect(dlg.getByText(/The status stays .* until then\./)).toBeVisible();
  await dlg.getByRole('button', { name: 'Show me' }).first().click();
  await expect(dlg.locator('#domain-details')).toBeInViewport();
  const after = await one<{ s: string }>(
    `select status s from public.domain where name = 'Fullstack'`,
  );
  expect(after.s).toBe(before.s);
  // The testing channel and testing email are chosen right here.
  await expect(dlg.getByRole('heading', { name: 'Testing' })).toBeVisible();
  await expect(dlg.getByLabel('Testing email')).toBeVisible();
});

test('a Discord account held by another instructor: Release from them, then it is checked again', async ({
  page,
}) => {
  const a = await one<{ id: string }>(
    `update public.instructor set discord_user_id = '900000000000000077', discord_status = 'Found'
      where full_name = 'Test Instructor A' returning id`,
  );
  // The username first: changing it starts a check, and the check's answer is played below as a holder.
  await sql(
    `update public.instructor set discord_username = 'e2e.held', discord_user_id = null
      where full_name = 'Test Instructor F'`,
  );
  await sql(
    `delete from public.action_queue where action = 'discord_member' and status = 'Queued'`,
  );
  const f = await one<{ id: string }>(
    `update public.instructor set discord_status = 'Problem',
            discord_held_by = $1,
            discord_problem = 'This Discord account is already linked to Test Instructor A. If that is an old record of the same person or a mistake, press Release from Test Instructor A, then the account is linked here.'
      where full_name = 'Test Instructor F' returning id`,
    [a.id],
  );
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor F' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await expect(dlg.getByText(/already linked to Test Instructor A/)).toBeVisible();
  // Check Discord is never stuck: it can be pressed while a check is shown.
  await expect(dlg.getByRole('button', { name: 'Check Discord' })).toBeEnabled();
  await dlg.getByRole('button', { name: 'Release from Test Instructor A' }).click();
  await page
    .getByRole('dialog', { name: 'Release the Discord account from Test Instructor A?' })
    .getByRole('button', { name: 'Release from Test Instructor A' })
    .click();
  await expect(
    page.getByText('Released from Test Instructor A. Checking Discord again.'),
  ).toBeVisible();
  const r = await one<{ held: string | null; st: string }>(
    `select (select discord_user_id from public.instructor where id = $1) held,
            (select discord_status from public.instructor where id = $2) st`,
    [a.id, f.id],
  );
  expect(r).toEqual({ held: null, st: 'Checking' });
  await expect
    .poll(
      async () =>
        (
          await one<{ n: number }>(
            `select count(*)::int n from public.history_event where action = 'Discord account released from Test Instructor A'`,
          )
        ).n,
    )
    .toBe(1);
});

test('each domain lists only channels of its own approved server, and says when there is none', async ({
  page,
}) => {
  // Fullstack loses its approved servers; Backend keeps them.
  await sql(
    `delete from public.discord_server_domain where domain_id = (select id from public.domain where name = 'Fullstack')`,
  );
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor E' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await expect(
    dlg.getByText(
      'No Discord server is approved for Fullstack yet. An admin chooses and approves it on Setup, Domains.',
    ),
  ).toBeVisible();
  await expect(
    dlg.getByRole('combobox', { name: 'Channel of Test Instructor E in Fullstack' }),
  ).toHaveCount(0);
  await expect(
    dlg
      .getByRole('combobox', { name: 'Channel of Test Instructor E in Backend' })
      .locator('option', { hasText: '#test-instructor-a' }),
  ).toHaveCount(1);
});

// Owner, 23 November 2026 (decision 332): messages go at any hour; quiet hours are an optional domain setting, off.
test('an instructor can have a time zone, and quiet hours for instructors are off', async ({
  page,
}) => {
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor D' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  // The drawer saves by itself (autosave).
  await dlg.getByRole('combobox', { name: 'Time zone (optional)' }).selectOption('India');
  await expect
    .poll(
      async () =>
        (
          await one<{ tz: string | null }>(
            `select time_zone tz from public.instructor where full_name = 'Test Instructor D'`,
          )
        ).tz,
    )
    .toBe('India');

  await page.goto('/settings/automation');
  await ready(page);
  const sw = page.getByRole('switch', { name: 'Quiet hours for instructors' });
  await expect(async () => {
    if (!(await sw.isVisible())) {
      const det = page.locator('details', { hasText: 'Show more options' }).first();
      if (!(await det.evaluate((d) => (d as HTMLDetailsElement).open)))
        await det.locator('summary').click();
    }
    await expect(sw).toBeVisible({ timeout: 1_000 });
  }).toPass({ timeout: 15_000 });
  await expect(sw).toHaveAttribute('aria-checked', 'false');
});

// Decision 337: someone on the team writes to one instructor from their record.
test('Contact instructor sends a message to their channel and email, kept in Activity history', async ({
  page,
}) => {
  // Test Instructor C gets a Discord account and a checked channel, as a real instructor has.
  await sql(
    `update public.instructor set discord_username = 'e2e.instructor.c', version = version where full_name = 'Test Instructor C'`,
  );
  await sql(
    `delete from public.action_queue where action = 'discord_member' and status = 'Queued'`,
  );
  await sql(
    `update public.instructor set discord_user_id = '900000000000000095', discord_status = 'Found', version = version
      where full_name = 'Test Instructor C'`,
  );
  await sql(
    `insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name, ready_at)
     select i.id, d.id, ch.id, ch.name, now() from public.instructor i, public.domain d, public.discord_channel ch
      where i.full_name = 'Test Instructor C' and d.name = 'Backend' and ch.name = 'test-instructor-c'
     on conflict (instructor_id, domain_id) do update set channel_id = excluded.channel_id, ready_at = excluded.ready_at`,
  );
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor C' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByLabel('Message to Test Instructor C').fill('Can you share your slides by Friday?');
  await dlg.getByRole('button', { name: 'Send message' }).click();
  await expect(
    page.getByText('Message sent to Test Instructor C by Discord and email'),
  ).toBeVisible();
  const m = await one<{ n: number }>(
    `select count(*)::int n from public.message m join public.instructor i on i.id = m.instructor_id
      where i.full_name = 'Test Instructor C' and m.template_id = 'M23' and m.body_text like '%share your slides by Friday%'`,
  );
  expect(m.n).toBe(2);
  await expect(dlg.getByLabel('Message to Test Instructor C')).toHaveValue('');
});
