// Release 3, M2 to M4 (decisions 276 to 278, 286 to 288): admins, the beta list, who may receive messages and
// Discord servers approved by an admin. The test account is the only admin of the test data; one program server
// ("New program server") waits for approval.
import {
  a11y,
  expect,
  loadDemoData,
  noDashes,
  noSidewaysScroll,
  ready,
  sql,
  test,
} from './fixtures.ts';

test.describe.configure({ mode: 'default' });
// The test data makes the test account again on every load; link it to its sign in, as a real sign in does, so it
// is listed among the admins (only people who have signed in are).
test.beforeEach(async () => {
  await loadDemoData();
  await sql(
    `update public.team_member set auth_user_id = (select u.id from auth.users u where lower(u.email) = $1),
            version = version where lower(email) = $1`,
    ['ops.placeholder@example.com'],
  );
});
test.afterAll(() => loadDemoData());

const ME = 'ops.placeholder@example.com';
const serverRows = (page: import('@playwright/test').Page) =>
  page.locator('table').first().locator('tbody tr');

test('the Admin page shows who may sign in, the beta list, recipients and the admins', async ({
  page,
}) => {
  await page.goto('/settings/admin');
  await ready(page);
  // The page title also holds its help link ("Admin" and "Help for Admin").
  await expect(page.locator('main h1').first()).toHaveText(/^Admin/);
  for (const t of ['Who may sign in', 'Beta list', 'Who may receive messages', 'Admins'])
    await expect(page.getByRole('heading', { name: t, exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Admin', exact: true })).toBeVisible();
  await a11y(page, 'the Admin page');
  await noSidewaysScroll(page, 'the Admin page');
  await noDashes(page, 'the Admin page');
});

test('an admin adds a colleague to the beta list, and it is logged', async ({ page }) => {
  const dom = (
    await sql<{ d: string }>(`select company_email_domain d from public.app_config where id = 1`)
  )[0]!.d;
  const who = `beta.colleague@${dom}`;
  await page.goto('/settings/admin');
  await ready(page);
  await page.getByLabel('Email', { exact: true }).fill(who);
  await page.getByLabel('Note (optional)').fill('Agentic AI operations');
  await page.getByRole('button', { name: 'Add to the beta list' }).click();
  await expect(page.getByText(`${who} is on the beta list`)).toBeVisible();
  const r = await sql<{ n: number }>(
    `select count(*)::int n from public.beta_access where email = $1`,
    [who],
  );
  expect(r[0]!.n).toBe(1);
  const h = await sql<{ n: number }>(
    `select count(*)::int n from public.history_event where action ilike '%beta list%' and at > now() - interval '5 minutes'`,
  );
  expect(h[0]!.n).toBeGreaterThan(0);
});

test('the last admin cannot remove their own admin rights', async ({ page }) => {
  await page.goto('/settings/admin');
  await ready(page);
  const row = page.locator('li').filter({ hasText: ME });
  await expect(row.getByText('Admin', { exact: true })).toBeVisible();
  await expect(row.getByRole('button', { name: 'Remove admin rights' })).toBeDisabled();
});

test('a server waiting for approval is approved for one domain, and the bot reads it', async ({
  page,
}) => {
  await page.goto('/settings/connections');
  await ready(page);
  const row = serverRows(page).filter({ hasText: 'New program server' });
  await expect(row.getByText('Waiting for approval')).toBeVisible();
  await row.getByRole('button', { name: 'Approve' }).click();
  const dlg = page.getByRole('dialog', { name: 'Approve New program server' });
  await dlg.getByLabel('Backend').check();
  await dlg.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByText('New program server approved')).toBeVisible();
  await expect(row.getByText('For Backend')).toBeVisible();
  const s = await sql<{ access: string; n: number; q: number }>(
    `select s.access, (select count(*)::int from public.discord_server_domain x where x.server_id = s.id) n,
            (select count(*)::int from public.action_queue a where a.action = 'discord_server'
              and a.payload ->> 'server_id' = s.id) q
       from public.discord_server s where s.id = '900000000000000117'`,
  );
  expect(s[0]).toEqual({ access: 'Approved', n: 1, q: 1 });
});

test('a refused server is never offered to a domain', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  const row = serverRows(page).filter({ hasText: 'New program server' });
  await row.getByRole('button', { name: 'Refuse' }).click();
  await expect(
    page.getByText('New program server refused. The bot does nothing there.'),
  ).toBeVisible();
  await expect(row.getByText('Refused')).toBeVisible();
  const picker = page.getByRole('combobox', { name: 'Discord server for Backend' });
  await expect(picker.locator('option', { hasText: 'New program server' })).toHaveCount(0);
  await expect(picker.locator('option', { hasText: 'Program server 2' })).toHaveCount(1);
});

test('someone who is not an admin sees no admin controls', async ({ page }) => {
  await sql(`update public.team_member set is_admin = false, version = version where email = $1`, [
    ME,
  ]);
  await page.goto('/settings/connections');
  await ready(page);
  await expect(page.getByRole('button', { name: 'Refresh servers' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Approve' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Send a test' })).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Admin', exact: true })).toHaveCount(0);
  await page.goto('/settings/admin');
  await ready(page);
  await expect(page.getByText('Only an admin can see this page.')).toBeVisible();
});

test('Connections: set up and nothing sent reads Ready; an admin sends a Discord and an email test, both logged', async ({
  page,
}) => {
  // Release 3, A7 (decision 310): never "Not connected" just because nothing was sent yet.
  await sql(
    `update public.message set status = 'Cancelled' where status in ('Sent', 'Failed', 'Pending', 'Scheduled')`,
  );
  // Email is sent by the automation service, so it is ready once the service has handled work.
  await sql(
    `insert into public.action_queue (action, payload, status, processed_at) values ('deliver', '{}', 'Done', now())`,
  );
  await sql(
    `update public.app_config set scheduling_email = coalesce(scheduling_email, 'sender@example.com'),
            admin_discord_channel_id = coalesce(admin_discord_channel_id, (
              select ch.id from public.discord_channel ch join public.discord_server s on s.id = ch.server_id
               where s.access = 'Approved' order by ch.name limit 1)) where id = 1`,
  );
  await page.goto('/settings/connections');
  await ready(page);
  await expect(page.getByText('Ready, no messages yet')).toHaveCount(2);
  await expect(page.getByText('Not connected')).toHaveCount(0);
  await a11y(page, 'connections ready');
  await noDashes(page, 'connections ready');
  // Counted before and after: other tests (the crawl presses every button) may have sent tests already.
  const count = () =>
    sql<{ d: number; e: number; h: number }>(
      `select count(*) filter (where channel = 'Discord')::int d, count(*) filter (where channel = 'Email' and lower(to_address) = $1)::int e,
              (select count(*)::int from public.history_event where action like 'Connection test sent: %') h
         from public.message where template_id = 'T21'`,
      [ME],
    );
  const [b] = await count();
  const tests = page.getByRole('button', { name: 'Send a test' });
  await expect(tests).toHaveCount(2);
  await tests.first().click();
  await expect(page.getByText('Test sent to the admin alert channel.')).toBeVisible();
  await tests.last().click();
  await expect(page.getByText('Test email sent to your own address.')).toBeVisible();
  const [m] = await count();
  expect({ d: m!.d - b!.d, e: m!.e - b!.e, h: m!.h - b!.h }).toEqual({ d: 1, e: 1, h: 2 });
});

// Release 3, B3 (decision 312): a domain's Discord server is chosen in Setup, Domains.
async function openBackend(page: import('@playwright/test').Page) {
  await page.goto('/setup/domains');
  await ready(page);
  await page.getByRole('button', { name: 'Backend', exact: true }).click();
  const d = page.getByRole('dialog', { name: 'Backend' });
  await expect(d).toBeVisible();
  await ready(page);
  return d;
}

test('Setup, Domains: an admin approves a waiting server for the domain, chooses a server, and the alert channel is right there', async ({
  page,
}) => {
  const d = await openBackend(page);
  const waiting = d.getByRole('list', { name: 'Servers not approved for a domain yet' });
  await expect(waiting).toContainText('New program server');
  await a11y(page, 'domain discord server');
  await noDashes(page, 'domain discord server');
  const [{ n: before }] = await sql<{ n: number }>(
    `select count(*)::int n from public.history_event where action = 'Discord server approved'`,
  );
  await waiting
    .getByRole('button', { name: /^Approve for this domain/ })
    .filter({ hasText: 'New program server' })
    .click();
  await expect(page.getByText('New program server approved for Backend')).toBeVisible();
  const [a] = await sql<{ n: number; h: number }>(
    `select (select count(*)::int from public.discord_server_domain sd join public.domain dd on dd.id = sd.domain_id
              where sd.server_id = '900000000000000117' and dd.name = 'Backend') n,
            (select count(*)::int from public.history_event where action = 'Discord server approved') h`,
  );
  expect(a).toEqual({ n: 1, h: before! + 1 });
  await d
    .getByRole('combobox', { name: 'Discord server' })
    .selectOption({ label: 'Program server 2' });
  await expect(page.getByText('Server saved. Checking it now.')).toBeVisible();
  const [s] = await sql<{ id: string }>(
    `select discord_server_id id from public.domain where name = 'Backend'`,
  );
  expect(s!.id).toBe('900000000000000102');
  await expect(d.getByRole('combobox', { name: 'Alert channel' })).toBeVisible();
});

test('Setup, Domains: a normal user sees only the servers approved for the domain, and one clear step when there is none', async ({
  page,
}) => {
  await sql(`update public.team_member set is_admin = false, version = version where email = $1`, [
    ME,
  ]);
  let d = await openBackend(page);
  await expect(d.getByRole('button', { name: /^Approve for this domain/ })).toHaveCount(0);
  await expect(
    d
      .getByRole('combobox', { name: 'Discord server' })
      .locator('option', { hasText: 'New program server' }),
  ).toHaveCount(0);
  await sql(
    `delete from public.discord_server_domain where domain_id = (select id from public.domain where name = 'Backend')`,
  );
  await sql(
    `update public.domain set discord_server_id = null, version = version where name = 'Backend'`,
  );
  d = await openBackend(page);
  await expect(
    d.getByText(
      'No Discord server is approved for Backend yet. Add the bot to your Discord server with the invite link, then wait for an admin to approve the server for this domain.',
      { exact: false },
    ),
  ).toBeVisible();
  await a11y(page, 'domain without a discord server');
});

// Owner's urgent list of 23 November 2026 (decision 329): a message a beta rule stops is never silent, and once the
// person is on the beta list, Send again delivers it.
test('a blocked message shows on the instructor with the reason, and goes out after the beta list allows it', async ({
  page,
}) => {
  await sql(
    `update public.app_config set message_recipients = 'Test instructors and signed in colleagues',
            recipient_email_domains = '{example.com}', beta_list_may_receive = true where id = 1`,
  );
  const [i] = await sql<{ id: string; email: string }>(
    `update public.instructor set is_test = false, version = version where full_name = 'Test Instructor E'
     returning id, primary_email email`,
  );
  await sql(`delete from public.beta_access where email = $1`, [i!.email]);
  await sql(
    `insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, to_address,
       instructor_id, subject, body_text)
     values ('Instructor', 'M1', 'Email', 'Pending', 'e2e-blocked-1', 'Test Instructor E', $1, $2, 'Test', 'Test')`,
    [i!.email, i!.id],
  );
  const [m] = await sql<{ status: string; blocked: boolean }>(
    `select status, blocked from public.message where unique_key = 'e2e-blocked-1'`,
  );
  expect(m).toEqual({ status: 'Cancelled', blocked: true });

  await page.goto('/setup/instructors');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor E' }).first().click();
  const dlg = page.getByRole('dialog');
  await expect(dlg.getByText('A message was not sent')).toBeVisible();
  await expect(
    dlg.getByText(/Not sent: during the beta, messages go only to test instructors/),
  ).toBeVisible();
  await a11y(page, 'blocked message notice');
  await noDashes(page, 'blocked message notice');

  // An admin puts their email on the beta list; Send again delivers it.
  await sql(`insert into public.beta_access (email) values ($1) on conflict do nothing`, [
    i!.email,
  ]);
  await dlg.getByRole('button', { name: 'Send again' }).click();
  await expect(dlg.getByText('A message was not sent')).toHaveCount(0);
  const [again] = await sql<{ n: number }>(
    `select count(*)::int n from public.message where unique_key like 'e2e-blocked-1:resend:%'
        and status in ('Pending', 'Scheduled', 'Sending', 'Sent') and not blocked`,
  );
  expect(again!.n).toBe(1);
  const [h] = await sql<{ n: number }>(
    `select count(*)::int n from public.history_event where action like 'Sent again after it was blocked:%'`,
  );
  expect(h!.n).toBeGreaterThan(0);
});

// This setting outlives a reload of the test data, so it is put back for the tests that follow.
test.describe('the beta rule', () => {
  test.afterEach(async () => {
    await sql(
      `update public.app_config set message_recipients = 'Anyone', version = version where id = 1`,
    );
    await sql(`update public.team_member set is_admin = true, version = version where email = $1`, [
      ME,
    ]);
  });

  test('during the beta, someone who is not an admin cannot tick Test instructor or change emails and Discord', async ({
    page,
  }) => {
    await sql(
      `update public.app_config set message_recipients = 'Test instructors and signed in colleagues', version = version
      where id = 1`,
    );
    await sql(
      `update public.team_member set is_admin = false, version = version where email = $1`,
      [ME],
    );
    await page.goto('/setup/instructors');
    await ready(page);
    await page.getByLabel('Show test instructors').check();
    await page.locator('tbody tr').filter({ hasText: 'Test Instructor F' }).first().click();
    const dlg = page.getByRole('dialog');
    await ready(page);
    await expect(dlg.getByRole('checkbox', { name: /Test instructor/ })).toBeDisabled();
    await expect(dlg.getByRole('textbox', { name: /^Email/ })).toBeDisabled();
    await expect(dlg.getByLabel('Discord username')).toBeDisabled();
    await expect(dlg.getByRole('button', { name: 'Add another email' })).toHaveCount(0);
    await expect(
      dlg.getByText('During the beta, only an admin changes Test instructor', { exact: false }),
    ).toBeVisible();
    // Every other detail still saves.
    await expect(dlg.getByLabel('Phone')).toBeEnabled();
    await a11y(page, 'instructor locked during the beta', '[role="dialog"]');
    await noDashes(page, 'instructor locked during the beta');

    // An admin changes them as before.
    await sql(`update public.team_member set is_admin = true, version = version where email = $1`, [
      ME,
    ]);
    await page.reload();
    await ready(page);
    await page.getByLabel('Show test instructors').check();
    await page.locator('tbody tr').filter({ hasText: 'Test Instructor F' }).first().click();
    await expect(
      page.getByRole('dialog').getByRole('checkbox', { name: /Test instructor/ }),
    ).toBeEnabled();
    await expect(page.getByRole('dialog').getByLabel('Discord username')).toBeEnabled();
  });
});
