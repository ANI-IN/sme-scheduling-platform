// Core readiness step 6: a bot in 15 or more Discord servers (decisions 261 to 263). The test data puts the
// bot in 16 servers ("Program server 1" to 16), the first with channels in a "Test instructors" category.
import { a11y, expect, loadDemoData, noSidewaysScroll, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
test.beforeEach(() => loadDemoData());
test.afterAll(() => loadDemoData());

const list = (page: import('@playwright/test').Page) =>
  page.locator('table').first().locator('tbody tr');
/** The 16 servers of the test data (another spec may have added the test server itself). */
const programServers = (page: import('@playwright/test').Page) =>
  list(page).filter({ hasText: /Program server \d+/ });

test('every server is listed with its own status', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  await expect(programServers(page)).toHaveCount(16);
  await expect(
    list(page).filter({ hasText: 'Program server 5' }).getByText('Needs a fix'),
  ).toBeVisible();
  await expect(
    list(page).filter({ hasText: 'Program server 7' }).getByText('Not checked yet').first(),
  ).toBeVisible();
  await expect(list(page).filter({ hasText: 'Program server 2' }).getByText('Ready')).toBeVisible();
  await a11y(page, 'the server list');
  await noSidewaysScroll(page, 'the server list');
});

test('search narrows the list by name or ID', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  await page.getByLabel('Search servers').fill('server 1');
  // Program server 1 and 10 to 16.
  await expect(list(page)).toHaveCount(8);
  await page.getByLabel('Search servers').fill('900000000000000112');
  await expect(list(page)).toHaveCount(1);
  await expect(list(page).first()).toContainText('Program server 12');
  await page.getByLabel('Search servers').fill('nothing like this');
  await expect(page.getByText('No server matches your search.')).toBeVisible();
});

test('Check again checks one server now', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  const row = list(page).filter({ hasText: 'Program server 3' });
  await row.getByRole('button', { name: 'Check again' }).click();
  await expect(
    page.getByText('Checking Program server 3. This takes up to a minute.'),
  ).toBeVisible();
  await expect(row.getByText('Checking')).toBeVisible();
  const q = await sql<{ n: number }>(
    `select count(*)::int n from public.action_queue where action = 'discord_server' and status = 'Queued'
        and payload ->> 'server_id' = '900000000000000103'`,
  );
  expect(q[0]!.n).toBe(1);
});

test('archive hides a server, Show archived brings it back, and restore', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  await list(page)
    .filter({ hasText: 'Program server 4' })
    .getByRole('button', { name: 'Archive', exact: true })
    .click();
  await page
    .getByRole('dialog', { name: 'Archive Program server 4?' })
    .getByRole('button', { name: 'Archive' })
    .click();
  await expect(page.getByText('Program server 4 archived')).toBeVisible();
  await expect(programServers(page)).toHaveCount(15);
  await page.getByLabel(/Show archived servers/).check();
  const row = list(page).filter({ hasText: 'Program server 4' });
  await expect(row.getByText('Archived')).toBeVisible();
  await row.getByRole('button', { name: 'Restore' }).click();
  await expect(page.getByText('Program server 4 restored')).toBeVisible();
});

test('delete forgets a server the bot is in, and says the bot stays there', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  await list(page)
    .filter({ hasText: 'Program server 16' })
    .getByRole('button', { name: 'Delete permanently' })
    .click();
  const dlg = page.getByRole('dialog', { name: 'Delete this Discord server permanently?' });
  await expect(dlg.getByText(/The bot stays in the server/)).toBeVisible();
  await dlg.getByRole('button', { name: 'Delete permanently' }).click();
  await expect(page.getByText('Program server 16 deleted')).toBeVisible();
  await expect(programServers(page)).toHaveCount(15);
});

test('an instructor channel can come from a server approved for the domain, checked in Discord first', async ({
  page,
}) => {
  // Decisions 330 and 331: only servers approved for the domain are offered, and a chosen channel is checked in
  // Discord (the bot can post, the instructor can see it) before it is saved.
  await sql(
    `update public.instructor set discord_user_id = '900000000000000096', discord_status = 'Found', version = version
      where full_name = 'Test Instructor A'`,
  );
  await page.goto('/setup/instructors');
  await ready(page);
  await page.getByLabel('Show test instructors').check();
  await page.locator('tbody tr').filter({ hasText: 'Test Instructor A' }).first().click();
  const dlg = page.getByRole('dialog', { name: 'Test Instructor A' });
  await ready(page);
  const picker = dlg.getByRole('combobox', { name: 'Channel of Test Instructor A in Backend' });
  await dlg
    .getByLabel('Search channels for Channel of Test Instructor A in Backend')
    .fill('test-instructor-a');
  await picker.selectOption({ label: 'Program server 1: Test instructors / #test-instructor-a' });
  await expect(dlg.getByText(/Checking #test-instructor-a in Discord/)).toBeVisible();
  const [w] = await sql<{ id: string; server: string }>(
    `select a.id, a.payload ->> 'server_id' server from public.action_queue a
      where a.action = 'discord_channel' and a.status = 'Queued' order by a.created_at desc limit 1`,
  );
  await sql(`select public.record_discord_result($1, $2::jsonb)`, [
    w!.id,
    JSON.stringify({
      channel: {
        status: 200,
        body: {
          id: '900000000000000201',
          name: 'test-instructor-a',
          permission_overwrites: [{ id: '900000000000000302', type: 0, allow: '66560', deny: '0' }],
        },
      },
      roles: {
        status: 200,
        body: [
          { id: w!.server, permissions: '0' },
          { id: '900000000000000301', permissions: '84992' },
          { id: '900000000000000302', permissions: '0' },
        ],
      },
      bot: {
        status: 200,
        body: { user: { id: '900000000000000098' }, roles: ['900000000000000301'] },
      },
      member: {
        status: 200,
        body: { user: { id: '900000000000000096' }, roles: ['900000000000000302'] },
      },
    }),
  ]);
  await expect(dlg.getByText('Channel ready')).toBeVisible({ timeout: 15_000 });
  const c = await sql<{ c: string }>(
    `select ic.channel_id c from public.instructor_channel ic join public.instructor i on i.id = ic.instructor_id
       join public.domain d on d.id = ic.domain_id where i.full_name = 'Test Instructor A' and d.name = 'Backend'`,
  );
  expect(c[0]!.c).toBe('900000000000000201');
});
