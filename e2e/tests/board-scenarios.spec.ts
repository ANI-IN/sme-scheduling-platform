// Release 3, M12b (decision 314): bulk actions on the Schedule board. Select several class weeks; each action shows
// one combined preview before anything is saved. The rules behind each are covered by the database tests 420, 440
// and 510.
import { a11y, expect, loadDemoData, noDashes, ready, sql, test } from './fixtures.ts';
import { layoutOk } from './layout.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

async function openBoard(page: import('@playwright/test').Page) {
  await page.goto('/board');
  await ready(page);
  await page.getByRole('button', { name: 'Select class weeks' }).click();
  return page.getByRole('region', { name: 'Selected class weeks' });
}
const selectable = (page: import('@playwright/test').Page) =>
  page.getByRole('button', { name: /^Select: Open / });

test('select two class weeks and cancel them, with one combined preview and a reason', async ({
  page,
}) => {
  const bar = await openBoard(page);
  await expect(bar.getByText('Click class weeks to select them.')).toBeVisible();
  await selectable(page).nth(0).click();
  await selectable(page).nth(1).click();
  await expect(bar.getByText('2 class weeks selected')).toBeVisible();
  await expect(page.getByRole('button', { name: /^Selected: Open / })).toHaveCount(2);
  await bar.getByRole('button', { name: 'Cancel', exact: true }).click();
  const dlg = page.getByRole('dialog', { name: 'Cancel 2 class weeks' });
  await expect(
    dlg.getByRole('list', { name: 'Selected class weeks' }).locator(':scope > li'),
  ).toHaveCount(2);
  await a11y(page, 'bulk cancel preview');
  await noDashes(page, 'bulk cancel preview');
  await expect(dlg.getByRole('button', { name: 'Cancel class weeks' })).toBeDisabled();
  await dlg.getByLabel('Reason').fill('E2E: the rooms are closed');
  await dlg.getByRole('button', { name: 'Cancel class weeks' }).click();
  await expect(page.getByText('2 class weeks cancelled')).toBeVisible({ timeout: 20_000 });
  const [h] = await sql<{ n: number }>(
    `select count(*)::int n from public.history_event where action = 'Class weeks cancelled from the Schedule board: 2'
        and note = 'E2E: the rooms are closed'`,
  );
  expect(h!.n).toBe(1);
});

test('Move shows every selected class week and what changes, and saves nothing until Move', async ({
  page,
}) => {
  const bar = await openBoard(page);
  await selectable(page).nth(0).click();
  await selectable(page).nth(1).click();
  const before = await sql<{ n: number }>(`select count(*)::int n from public.history_event`);
  await bar.getByRole('button', { name: 'Move', exact: true }).click();
  const dlg = page.getByRole('dialog', { name: 'Move 2 class weeks' });
  await dlg.getByRole('combobox', { name: 'Move by' }).selectOption({ label: '1 week later' });
  await expect(dlg.getByRole('region', { name: 'What changes' })).toBeVisible();
  await expect(
    dlg.getByRole('list', { name: 'Selected class weeks' }).locator(':scope > li'),
  ).toHaveCount(2);
  await a11y(page, 'bulk move preview');
  await dlg.getByRole('button', { name: 'Go back' }).click();
  const after = await sql<{ n: number }>(`select count(*)::int n from public.history_event`);
  expect(after[0]!.n).toBe(before[0]!.n);
});

test('Add a break starts from the selection, and one shared class needs two class weeks', async ({
  page,
}) => {
  const bar = await openBoard(page);
  await selectable(page).nth(0).click();
  await expect(bar.getByRole('button', { name: 'Make one shared class' })).toBeDisabled();
  await bar.getByRole('button', { name: 'Add a break' }).click();
  const dlg = page.getByRole('dialog', { name: 'Add a break' });
  await expect(dlg).toBeVisible();
  await expect(dlg.getByRole('textbox', { name: 'First day', exact: true })).not.toHaveValue('');
});

// Release 3 board review, items 6, 8, 9 and 10: the first week shown, By instructor on a phone, and the
// group of cohorts without a standard schedule.
test('the board opens at this week, and Earlier still shows the weeks before', async ({ page }) => {
  await page.goto('/board');
  await ready(page);
  const rows = page.locator('main table tbody tr');
  await expect(rows.first()).toHaveAttribute('aria-current', 'date');
  await expect(rows.first().getByRole('rowheader')).toContainText('This week');
  await page.getByRole('button', { name: 'Earlier', exact: true }).click();
  await ready(page);
  await expect(page.locator('main [aria-current="date"]')).toHaveCount(0);
  await page.getByRole('button', { name: 'This week', exact: true }).click();
  await ready(page);
  await expect(rows.first()).toHaveAttribute('aria-current', 'date');
});

// The Legend moved to the Legend and help panel (decision 344): help-panel-scenarios.spec.ts.

test('cohorts without a standard schedule are grouped as No standard schedule', async ({
  page,
}) => {
  await page.goto('/board');
  await ready(page);
  await expect(
    page.getByRole('button', { name: /^No standard schedule \(\d+\)$/ }).first(),
  ).toBeVisible();
  await expect(page.getByText('Other cohorts')).toHaveCount(0);
});

test('By instructor on a phone shows each instructor with their class weeks as cards', async ({
  page,
}) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto('/board');
  await ready(page);
  await page.getByRole('button', { name: 'By instructor', exact: true }).click();
  await expect(page.locator('main table')).toHaveCount(0);
  const lists = page.getByRole('list', { name: /^Class weeks of / });
  await expect(lists.first()).toBeVisible();
  const n = await lists.count();
  // One heading per instructor, and no instructor without a class week (no empty rows).
  await expect(page.getByRole('heading', { level: 2, name: /class weeks?\)$/ })).toHaveCount(n);
  for (const l of await lists.all()) {
    expect(await l.locator(':scope > li').count()).toBeGreaterThan(0);
    await expect(l.locator(':scope > li').first()).toContainText('Week of');
  }
  await expect(page.getByRole('button', { name: /^Open / }).first()).toBeVisible();
  await layoutOk(page, 'board by instructor on a phone');
  await a11y(page, 'board by instructor on a phone');
  await noDashes(page, 'board by instructor on a phone');
  // A desktop keeps the grid.
  await page.setViewportSize({ width: 1440, height: 900 });
  await expect(page.locator('main table')).toBeVisible();
  await expect(lists).toHaveCount(0);
});
