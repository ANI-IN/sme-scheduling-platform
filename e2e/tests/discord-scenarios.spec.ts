// Discord scenarios (Release 2 Milestones C and D), on the Sandbox starting data. Nothing reaches
// Discord here: the app queues each check, and the test plays the automation's part with
// record_discord_result, using made up server, channel and member data.
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;
const SERVER = '900000000000000001';
const CHANNELS = [
  { id: '900000000000000010', type: 4, name: '1-1', position: 1 },
  {
    id: '900000000000000011',
    type: 0,
    name: 'test-instructor-f',
    parent_id: '900000000000000010',
    position: 1,
  },
  {
    id: '900000000000000012',
    type: 0,
    name: 'test-instructor-e',
    parent_id: '900000000000000010',
    position: 2,
  },
  { id: '900000000000000013', type: 0, name: 'backend-alerts', position: 0 },
];

/** Answer the newest waiting Discord check the way the automation would. */
async function answer(action: string, result: object) {
  await expect
    .poll(
      async () =>
        (
          await one<{ n: number }>(
            `select count(*)::int n from public.action_queue where action = $1 and status = 'Queued'`,
            [action],
          )
        ).n,
      { timeout: 10_000 },
    )
    .toBeGreaterThan(0);
  await sql(
    `select public.record_discord_result(
       (select id from public.action_queue where action = $1 and status = 'Queued' order by created_at desc limit 1),
       $2::jsonb)`,
    [action, JSON.stringify(result)],
  );
}

test('Discord servers: refresh, choose a server, see a fix, then its channels', async ({
  page,
}) => {
  await page.goto('/settings/connections');
  await ready(page);
  await expect(page.getByRole('heading', { name: 'Discord servers' })).toBeVisible();
  await expect(
    page.getByText(/View Channels, Send Messages, Embed Links and Read Message History/).first(),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Refresh servers' }).click();
  await answer('discord_servers', {
    guilds: { status: 200, body: [{ id: SERVER, name: 'E2E Backend server' }] },
  });
  await page.reload();
  await ready(page);
  // A new server waits for an admin (decision 288): it is not offered to a domain until it is approved.
  const picker = page.getByRole('combobox', { name: 'Discord server for Backend' });
  await expect(picker.locator('option', { hasText: 'E2E Backend server' })).toHaveCount(0);
  const row = page
    .locator('table')
    .first()
    .locator('tbody tr')
    .filter({ hasText: 'E2E Backend server' });
  await expect(row.getByText('Waiting for approval')).toBeVisible();
  await row.getByRole('button', { name: 'Approve' }).click();
  const dlg = page.getByRole('dialog', { name: 'Approve E2E Backend server' });
  await dlg.getByLabel('Backend').check();
  await dlg.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByText('E2E Backend server approved')).toBeVisible();
  await picker.selectOption({ label: 'E2E Backend server' });
  // Approving queued a check of the new server: answer it once the domain uses it.
  await expect
    .poll(
      async () =>
        (
          await one<{ s: string | null }>(
            `select discord_server_id s from public.domain where name = 'Backend'`,
          )
        ).s,
      { timeout: 10_000 },
    )
    .toBe(SERVER);
  // First answer: the bot cannot see any channel, so the screen says exactly what to fix.
  await answer('discord_server', {
    guild: { status: 200, body: { name: 'E2E Backend server' } },
    channels: { status: 200, body: [] },
    members: { status: 200 },
  });
  await page.reload();
  await ready(page);
  await expect(page.getByText('Needs a fix').first()).toBeVisible();
  // Shown on the server's own row and on the domain's row.
  await expect(
    page.getByText(/cannot see any text channels in E2E Backend server/).first(),
  ).toBeVisible();
  // After the fix: press Check, and the channels arrive.
  await page.getByRole('button', { name: 'Check', exact: true }).first().click();
  await answer('discord_server', {
    guild: { status: 200, body: { name: 'E2E Backend server' } },
    channels: { status: 200, body: CHANNELS },
    members: { status: 200 },
  });
  await page.reload();
  await ready(page);
  await expect(page.getByText('Ready', { exact: true }).first()).toBeVisible();
  await expect(page.getByText('3 channels the bot can see')).toBeVisible();
  const d = await one<{ s: string; st: string }>(
    `select discord_server_id s, discord_status st from public.domain where name = 'Backend'`,
  );
  expect(d).toEqual({ s: SERVER, st: 'Ready' });
});

test('an instructor: the app finds the username, a channel is chosen by search', async ({
  page,
}) => {
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor F' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await expect(dlg.getByText('Preferred contact')).toHaveCount(0);
  await dlg.getByLabel('Discord username').fill('@E2E.Instructor.F');
  await dlg.getByRole('button', { name: 'Save changes' }).click();
  const row = page.locator('tbody tr').filter({ hasText: 'Test Instructor F' }).first();
  await expect(row.getByText('Checking Discord')).toBeVisible();
  const i = await one<{ id: string; u: string }>(
    `select id, discord_username u from public.instructor where full_name = 'Test Instructor F'`,
  );
  expect(i.u).toBe('e2e.instructor.f');
  await answer('discord_member', {
    searches: [
      {
        server_id: SERVER,
        status: 200,
        body: [{ user: { id: '900000000000000099', username: 'e2e.instructor.f' } }],
      },
    ],
  });
  // The list looks again by itself while a check is running.
  await expect(row.getByText('Checking Discord')).toHaveCount(0, { timeout: 15_000 });
  await row.click();
  await ready(page);
  await expect(dlg.getByText('Discord found')).toBeVisible();
  await dlg
    .getByLabel('Search channels for Channel of Test Instructor F in Backend')
    .fill('instructor-f');
  await dlg
    .getByRole('combobox', { name: 'Channel of Test Instructor F in Backend' })
    .selectOption({ label: 'E2E Backend server: 1-1 / #test-instructor-f' });
  await expect(page.getByText('Channel saved')).toBeVisible();
  const ch = await one<{ c: string; n: string }>(
    `select channel_id c, channel_name n from public.instructor_channel where instructor_id = $1`,
    [i.id],
  );
  expect(ch).toEqual({ c: '900000000000000011', n: 'test-instructor-f' });
});

test('a username nobody has: the app says what to check, and Check Discord tries again', async ({
  page,
}) => {
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor E' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByLabel('Discord username').fill('nobody.here');
  await dlg.getByRole('button', { name: 'Save changes' }).click();
  const row = page.locator('tbody tr').filter({ hasText: 'Test Instructor E' }).first();
  await expect(row.getByText('Checking Discord')).toBeVisible();
  await answer('discord_member', { searches: [{ server_id: SERVER, status: 200, body: [] }] });
  await expect(row.getByText('Not found on Discord')).toBeVisible({ timeout: 15_000 });
  await row.click();
  await ready(page);
  await expect(dlg.getByText('Not found on Discord')).toBeVisible();
  await expect(
    dlg.getByText(/Nobody with the username nobody.here is in E2E Backend server/),
  ).toBeVisible();
  await dlg.getByRole('button', { name: 'Check Discord' }).click();
  await expect(page.getByText('Checking Discord').first()).toBeVisible();
  if (!(await dlg.isVisible())) {
    await row.click();
    await ready(page);
  }
  // An old style name with # is explained in plain words before anything is saved.
  await dlg.getByLabel('Discord username').fill('nobody#1234');
  await dlg.getByLabel('Discord username').blur();
  await expect(dlg.getByText(/without # and numbers/)).toBeVisible();
});

test('a domain alert channel comes from the list; Discord checks are in Activity history', async ({
  page,
}) => {
  await page.goto('/setup/domains');
  await ready(page);
  await page.locator('tbody tr').filter({ hasText: 'Backend' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg
    .getByRole('combobox', { name: 'Alert channel' })
    .selectOption({ label: '#backend-alerts' });
  await dlg.getByRole('button', { name: 'Save changes' }).click();
  await expect
    .poll(
      async () =>
        (
          await one<{ a: string | null }>(
            `select alert_discord_channel_id a from public.domain where name = 'Backend'`,
          )
        ).a,
    )
    .toBe('900000000000000013');
  await page.goto('/activity');
  await ready(page);
  await page.getByRole('combobox', { name: 'Type of change' }).selectOption('Discord');
  await ready(page);
  await expect(page.getByText(/Discord account found/).first()).toBeVisible();
  await expect(
    page.getByText(/Discord server checked|Discord server has a problem/).first(),
  ).toBeVisible();
});

test('a contact check goes to the instructor channel with a tag, plus email, never twice', async ({
  page,
  problems,
}) => {
  const i = await one<{ id: string }>(
    `select id from public.instructor where full_name = 'Test Instructor F'`,
  );
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor F' }).first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByRole('button', { name: 'Send contact check' }).click();
  await expect
    .poll(
      async () =>
        (
          await one<{ n: number }>(
            `select count(*)::int n from public.message where instructor_id = $1 and template_id = 'M15'`,
            [i.id],
          )
        ).n,
    )
    .toBeGreaterThan(0);
  const rows = await sql<{ channel: string; chan: string | null; mentions: string[] | null }>(
    `select channel, discord_channel_id chan, mention_user_ids mentions from public.message
      where instructor_id = $1 and template_id = 'M15' order by channel`,
    [i.id],
  );
  const discord = rows.filter((r) => r.channel === 'Discord');
  expect(rows.filter((r) => r.channel === 'Email')).toHaveLength(1);
  expect(discord).toHaveLength(1);
  expect(discord[0]!.chan).toBeTruthy();
  expect(discord[0]!.mentions ?? []).toContain('900000000000000099');
  // Pressing again does not send the same message twice while the first is waiting.
  const again = dlg.getByRole('button', { name: /Send contact check/ }).first();
  if (await again.isEnabled()) {
    const answered = page.waitForResponse(
      (r) => r.url().includes('/rest/v1/rpc/send_test_message'),
      {
        timeout: 15_000,
      },
    );
    // The database refuses it on purpose (400), and the screen says why.
    problems.allow.push(/HTTP 400: POST .*\/rest\/v1\/rpc\/send_test_message/, /status of 400/);
    await again.click();
    await answered;
    // The second press is refused while the first check is still on its way.
    await expect(dlg.getByText(/already on its way/)).toBeVisible();
  }
  const perWay = await sql<{ channel: string; n: number }>(
    `select channel, count(*)::int n from public.message where instructor_id = $1 and template_id = 'M15'
      group by channel order by channel`,
    [i.id],
  );
  expect(perWay).toEqual([
    { channel: 'Discord', n: 1 },
    { channel: 'Email', n: 1 },
  ]);
});
