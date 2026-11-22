// Release 3, M12b (decision 314): bulk actions on the Schedule board. Select several class weeks; each action shows
// one combined preview before anything is saved. The rules behind each are covered by the database tests 420, 440
// and 510.
import { a11y, expect, loadDemoData, noDashes, ready, sql, test } from './fixtures.ts';

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
