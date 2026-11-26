// Decision 350 (owner, 26 November 2026): the Discord server of a domain can be removed, archived domains stay out
// of the way and never count, and an admin can clear them all at once.
import { a11y, expect, loadDemoData, noSidewaysScroll, ready, sql, test } from './fixtures.ts';
import type { Page } from '@playwright/test';

const SERVER = '900000000000000101'; // "Program server 1" of the test data.

test.describe.configure({ mode: 'default' });
test.beforeEach(async () => {
  loadDemoData();
  await sql(`update public.discord_server set access = 'Approved' where id = $1`, [SERVER]);
  await sql(
    `insert into public.domain (name, status, discord_server_id)
     values ('SR Live', 'Live', $1), ('SR Draft', 'Draft', $1), ('SR Old', 'Draft', $1), ('SR Old approved', 'Draft', null)`,
    [SERVER],
  );
  await sql(
    `insert into public.discord_server_domain (server_id, domain_id)
     select $1, id from public.domain where name like 'SR %' on conflict do nothing`,
    [SERVER],
  );
  await sql(`update public.domain set archived_at = now() where name like 'SR Old%'`);
});
test.afterEach(async () => {
  await sql(`update public.team_member set is_admin = true, version = version where email = $1`, [
    'ops.placeholder@example.com',
  ]);
});
test.afterAll(() => loadDemoData());

const serverRow = (page: Page) =>
  page
    .locator('table')
    .first()
    .locator('tbody tr')
    .filter({ hasText: /Program server 1(?!\d)/ });
const domainRow = (page: Page, name: string) =>
  page
    .locator('table')
    .filter({ has: page.getByRole('columnheader', { name: 'Discord server' }) })
    .locator('tbody tr')
    .filter({
      has: page.getByRole('combobox', { name: `Discord server for ${name}`, exact: true }),
    });
const serverOf = async (name: string) =>
  (
    await sql<{ s: string | null }>(
      `select discord_server_id s from public.domain where name = $1`,
      [name],
    )
  )[0]!.s;
const open = async (page: Page) => {
  await page.goto('/settings/connections');
  await ready(page);
};

test('an admin removes the server of a domain, asked first; a Live domain keeps it', async ({
  page,
}) => {
  await open(page);
  await domainRow(page, 'SR Live').getByRole('button', { name: 'Remove server: SR Live' }).click();
  await expect(page.getByText('Set the domain to Draft or Paused first.')).toBeVisible();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(await serverOf('SR Live')).toBe(SERVER);

  // The list cannot take a server away without asking.
  const select = domainRow(page, 'SR Draft').getByRole('combobox');
  await expect(select.getByRole('option', { name: 'Choose a server' })).toBeDisabled();
  const remove = domainRow(page, 'SR Draft').getByRole('button', {
    name: 'Remove server: SR Draft',
  });
  await remove.click();
  const dlg = page.getByRole('dialog', { name: 'Remove the Discord server from SR Draft?' });
  await expect(
    dlg.getByText("This domain can't send Discord messages until a server is chosen again."),
  ).toBeVisible();
  await dlg.getByRole('button', { name: 'Go back' }).click();
  expect(await serverOf('SR Draft')).toBe(SERVER);

  await remove.click();
  await dlg.getByRole('button', { name: 'Remove server' }).click();
  await expect(page.getByText('Server removed from SR Draft')).toBeVisible();
  await expect(select).toHaveValue('');
  await expect(remove).toHaveCount(0);
  expect(await serverOf('SR Draft')).toBeNull();

  await page.goto('/activity');
  await ready(page);
  await expect(
    page.getByText(/removed the Discord server Program server 1 from SR Draft/).first(),
  ).toBeVisible();

  // The team can choose a server again.
  await open(page);
  await domainRow(page, 'SR Draft').getByRole('combobox').selectOption(SERVER);
  await expect(page.getByText('Server saved. Checking it now.')).toBeVisible();
  expect(await serverOf('SR Draft')).toBe(SERVER);
});

test('archived domains are out of sight and never count; they are cleared at once after a preview', async ({
  page,
}) => {
  await open(page);
  await expect(domainRow(page, 'SR Draft')).toBeVisible();
  await expect(domainRow(page, 'SR Old')).toHaveCount(0);
  const forList = serverRow(page).locator('td').nth(1);
  const usedBy = serverRow(page).locator('td').nth(4);
  await expect(forList).toContainText('SR Draft');
  await expect(forList).not.toContainText('SR Old');
  await expect(usedBy).toContainText('SR Draft');
  await expect(usedBy).not.toContainText('SR Old');

  await page.getByRole('switch', { name: 'Show archived', exact: true }).click();
  await expect(domainRow(page, 'SR Old').getByText('Archived', { exact: true })).toBeVisible();
  await expect(forList).toContainText('SR Old');
  await expect(usedBy).not.toContainText('SR Old');
  await a11y(page, 'the domains and servers with archived domains');
  await noSidewaysScroll(page, 'the domains and servers with archived domains');

  const all = page.getByRole('button', { name: 'Remove the server from all archived domains' });
  await all.click();
  const dlg = page.getByRole('dialog', { name: 'Remove the server from 2 archived domains?' });
  const preview = dlg.getByRole('list', { name: 'Archived domains to clear' });
  await expect(preview.getByRole('listitem')).toHaveText([
    'SR Old: Program server 1',
    'SR Old approved: Program server 1',
  ]);
  await dlg.getByRole('button', { name: 'Go back' }).click();
  expect(await serverOf('SR Old')).toBe(SERVER);

  await all.click();
  await dlg.getByRole('button', { name: 'Remove from 2 archived domains' }).click();
  await expect(page.getByText('Server removed from 2 archived domains')).toBeVisible();
  await expect(all).toHaveCount(0);
  await expect(forList).not.toContainText('SR Old');
  expect(await serverOf('SR Old')).toBeNull();
  expect(await serverOf('SR Draft')).toBe(SERVER);
  const left = await sql<{ n: number }>(
    `select count(*)::int n from public.discord_server_domain a join public.domain d on d.id = a.domain_id
      where d.archived_at is not null`,
  );
  expect(left[0]!.n).toBe(0);
});

test('someone who is not an admin cannot remove a server', async ({ page }) => {
  await sql(`update public.team_member set is_admin = false, version = version where email = $1`, [
    'ops.placeholder@example.com',
  ]);
  await open(page);
  await expect(domainRow(page, 'SR Draft')).toBeVisible();
  await expect(page.getByRole('button', { name: /^Remove server/ })).toHaveCount(0);
  await expect(
    page.getByRole('button', { name: 'Remove the server from all archived domains' }),
  ).toHaveCount(0);
  await expect(
    domainRow(page, 'SR Draft').getByRole('option', { name: 'Choose a server' }),
  ).toBeDisabled();
});
