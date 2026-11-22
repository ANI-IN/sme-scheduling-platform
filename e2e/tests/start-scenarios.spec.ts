// Core readiness step 6: an empty app and the Get started list (decisions 251, 253).
import { a11y, expect, loadDemoData, noSidewaysScroll, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
/** Empty the test stack the way "Reset Sandbox data" does. */
const empty = async () => {
  await sql(`select public.reset_sandbox_data('RESET')`);
  // The reset keeps real people, so people other specs added would tick "Add team members". Remove the ones
  // nobody signs in as, and take access away from the ones who signed in.
  await sql(
    `delete from public.team_member
      where auth_user_id is null and not is_placeholder and lower(email) like '%@example.com'`,
  );
  // The test account is a made up person, so the reset removes it; put it back as someone who already
  // answered the Discord question (a real person keeps their account).
  await sql(
    `insert into public.team_member (name, email, discord_prompt_dismissed_at)
     select 'Ops', 'ops.placeholder@example.com', now()
      where not exists (select 1 from public.team_member where lower(email) = 'ops.placeholder@example.com')`,
  );
  await sql(`update public.team_member set discord_prompt_dismissed_at = now(), version = version`);
  await sql(
    `update public.team_member set access_removed_at = now()
      where lower(email) <> 'ops.placeholder@example.com' and access_removed_at is null`,
  );
};
test.beforeEach(empty);
// Put the test data back for the specs after this one.
test.afterAll(() => loadDemoData());

const STEPS = [
  ['Add a domain', '/setup/domains'],
  ['Choose its Discord server', '/setup/domains'],
  ['Add team members', '/setup/team'],
  ['Add instructors', '/setup/instructors'],
  ['Add modules', '/setup/modules'],
  ['Create a cohort', '/setup/domains'],
  ['Plan classes', '/classes'],
] as const;

test('an empty app shows only the Get started list, with nothing done yet', async ({ page }) => {
  await page.goto('/');
  await ready(page);
  const list = page
    .getByRole('region', { name: 'Get started' })
    .or(page.locator('section', { hasText: 'Get started' }));
  await expect(list.first()).toBeVisible();
  for (const [label] of STEPS) await expect(page.getByRole('link', { name: label })).toBeVisible();
  await expect(page.locator('ol').first().getByLabel('Not done yet')).toHaveCount(STEPS.length);
  // No task counters or class tables for a domain that does not exist.
  await expect(page.getByText('Urgent tasks')).toHaveCount(0);
  await a11y(page, 'the empty Home page');
  await noSidewaysScroll(page, 'the empty Home page');
});

test('each step opens the page where it is done', async ({ page }) => {
  for (const [label, path] of STEPS) {
    await page.goto('/');
    await ready(page);
    await page.getByRole('link', { name: label }).click();
    await expect(page).toHaveURL(new RegExp(`${path}$`));
  }
});

test('the empty pages say what to do next', async ({ page }) => {
  for (const [path, text] of [
    ['/setup/domains', 'No domains yet'],
    ['/setup/instructors', /No instructors/],
    ['/classes', /domain/i],
  ] as const) {
    await page.goto(path);
    await ready(page);
    await expect(page.getByText(text).first()).toBeVisible();
  }
});

test('adding a domain in the app ticks the first step', async ({ page }) => {
  await page.goto('/setup/domains');
  await ready(page);
  await page.getByRole('button', { name: 'Create domain' }).first().click();
  await page.getByLabel('Domain name').fill('E2E Start');
  await page.getByRole('dialog').getByRole('button', { name: 'Create domain' }).click();
  await expect(page.getByText('Domain created')).toBeVisible();
  await page.goto('/');
  await ready(page);
  await expect(page.locator('ol').first().getByLabel('Done', { exact: true })).toHaveCount(1);
  await expect(page.getByRole('link', { name: 'Add a domain' })).toHaveCount(0);
  await expect(page.locator('ol').first().getByText('Add a domain')).toBeVisible();
});

test('a cohort and a team member tick their steps too', async ({ page }) => {
  const d = await sql<{ id: string }>(
    `insert into public.domain (name, status) values ('E2E Start', 'Draft') returning id`,
  );
  await sql(
    `insert into public.cohort (domain_id, name, region) values ($1, 'E2E Weekend', 'US')`,
    [d[0]!.id],
  );
  await sql(
    `insert into public.team_member (name, email) values ('E2E Helper', 'e2e.helper@example.com')`,
  );
  await page.goto('/');
  await ready(page);
  await expect(page.locator('ol').first().getByLabel('Done', { exact: true })).toHaveCount(3);
});
