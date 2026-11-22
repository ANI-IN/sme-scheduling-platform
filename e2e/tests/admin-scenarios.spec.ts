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
test.beforeEach(() => loadDemoData());
test.afterAll(() => loadDemoData());

const ME = 'ops.placeholder@example.com';
const serverRows = (page: import('@playwright/test').Page) =>
  page.locator('table').first().locator('tbody tr');

test('the Admin page shows who may sign in, the beta list, recipients and the admins', async ({
  page,
}) => {
  await page.goto('/settings/admin');
  await ready(page);
  await expect(page.getByRole('heading', { name: 'Admin', exact: true })).toBeVisible();
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
  await expect(page.getByRole('link', { name: 'Admin', exact: true })).toHaveCount(0);
  await page.goto('/settings/admin');
  await ready(page);
  await expect(page.getByText('Only an admin can see this page.')).toBeVisible();
});
