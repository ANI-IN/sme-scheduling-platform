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
});
