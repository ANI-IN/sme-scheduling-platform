// Final round (decision 271): Home, the task list and Activity history update by themselves, and a button
// updates the list and the counts at once. Release 3, C15: every page updates by itself, and small edits save by
// themselves.
import { expect, loadDemoData, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'default' });
test.beforeEach(() => loadDemoData());
test.afterAll(() => loadDemoData());

/** A new task for the Backend domain, as the automation would add it (a typed reply, an alert). */
async function addTask(title: string) {
  await sql(
    `insert into public.attention_item (domain_id, type, severity, title, detail, dedupe_key)
     select id, 'TypedReply', 'Urgent', $1, 'Please check the class time.', 'e2e-live:' || $1
       from public.domain where name = 'Backend'`,
    [title],
  );
}

test('a new task shows on Home without reloading the page', async ({ page }) => {
  await page.goto('/');
  await ready(page);
  await addTask('E2E live task on Home');
  // Live updates, or the 30 second check if a live update is missed.
  await expect(page.getByText('E2E live task on Home').first()).toBeVisible({ timeout: 45_000 });
});

test('a new task shows on the task list without reloading the page', async ({ page }) => {
  await page.goto('/attention');
  await ready(page);
  await addTask('E2E live task on the list');
  await expect(page.getByText('E2E live task on the list').first()).toBeVisible({
    timeout: 45_000,
  });
});

test('Mark done updates the task list at once', async ({ page }) => {
  await addTask('E2E task to mark done');
  await page.goto('/attention');
  await ready(page);
  const row = page.getByRole('listitem').filter({ hasText: 'E2E task to mark done' }).first();
  await expect(row).toBeVisible();
  await row.getByRole('button', { name: 'Mark done' }).click();
  const dlg = page.getByRole('dialog');
  if (await dlg.isVisible().catch(() => false)) {
    await dlg
      .getByRole('button', { name: /Mark done|Done/ })
      .last()
      .click();
  }
  await expect(page.getByText('E2E task to mark done')).toHaveCount(0, { timeout: 5_000 });
});

test('Activity history shows a new entry without reloading the page', async ({ page }) => {
  await page.goto('/activity');
  await ready(page);
  await sql(
    `select private.log_event('Team actions', 'E2E live history entry', null, null, null, null, null,
       (select id from public.domain where name = 'Backend'))`,
  );
  await expect(page.getByText(/E2E live history entry/).first()).toBeVisible({ timeout: 45_000 });
});

test('a module renamed somewhere else shows on its page without reloading', async ({ page }) => {
  const [m] = await sql<{ id: string; name: string }>(
    `select m.id, m.name from public.module m join public.domain d on d.id = m.domain_id
      where d.name = 'Backend' order by m.rotation_order limit 1`,
  );
  await page.goto(`/setup/modules/${m!.id}`);
  await ready(page);
  await expect(page.getByLabel('Name').first()).toHaveValue(m!.name);
  await sql(`update public.module set name = $2 where id = $1`, [m!.id, 'E2E live module name']);
  // Live updates, or the 60 second check if Realtime is not connected.
  await expect(page.getByRole('heading', { name: 'E2E live module name' })).toBeVisible({
    timeout: 75_000,
  });
  // The form has no unsaved edits, so it shows the new name too.
  await expect(page.getByLabel('Name').first()).toHaveValue('E2E live module name');
});

test('notes on an instructor save by themselves, with a Saved mark', async ({ page }) => {
  await page.goto('/setup/instructors');
  await ready(page);
  await page.locator('tbody tr').first().click();
  const dlg = page.getByRole('dialog');
  await ready(page);
  await dlg.getByLabel('Notes').fill('E2E note saved by itself');
  await expect(dlg.getByText('Saved', { exact: true })).toBeVisible();
  const [row] = await sql<{ n: number }>(
    `select count(*)::int n from public.instructor where notes = 'E2E note saved by itself'`,
  );
  expect(row!.n).toBe(1);
  // No Save button for it: Done just closes the drawer.
  await expect(dlg.getByRole('button', { name: 'Save changes' })).toHaveCount(0);
  await dlg.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(dlg).toHaveCount(0);
});
