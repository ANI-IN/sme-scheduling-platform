// Final round (decision 271): Home, the task list and Activity history update by themselves, and a button
// updates the list and the counts at once.
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
