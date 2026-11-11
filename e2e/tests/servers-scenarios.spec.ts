// Core readiness step 6: a bot in 15 or more Discord servers (decisions 261 to 263). The test data puts the
// bot in 16 servers ("Program server 1" to 16), the first with channels in a "Test instructors" category.
import { a11y, expect, loadDemoData, noSidewaysScroll, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
test.beforeEach(() => loadDemoData());
test.afterAll(() => loadDemoData());

const list = (page: import('@playwright/test').Page) =>
  page.locator('table').first().locator('tbody tr');

test('every server is listed with its own status', async ({ page }) => {
  await page.goto('/settings/connections');
  await ready(page);
  await expect(list(page)).toHaveCount(16);
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
  await expect(list(page)).toHaveCount(15);
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
  await expect(list(page)).toHaveCount(15);
});

test('an instructor channel can come from any server the bot is in', async ({ page }) => {
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
  await expect(page.getByText('Channel saved')).toBeVisible();
  const c = await sql<{ c: string }>(
    `select ic.channel_id c from public.instructor_channel ic join public.instructor i on i.id = ic.instructor_id
       join public.domain d on d.id = ic.domain_id where i.full_name = 'Test Instructor A' and d.name = 'Backend'`,
  );
  expect(c[0]!.c).toBe('900000000000000201');
});
