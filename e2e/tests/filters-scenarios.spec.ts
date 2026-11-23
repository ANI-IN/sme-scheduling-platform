// Release 3, C13 and C14: filters with several choices on Upcoming classes and the Schedule board. Fields combine
// with AND and the choices of one field with OR; each choice is a chip named "Remove <value>"; Clear all removes them;
// and the choices are remembered per person after a reload. Only the browser's storage changes, never the data.
import type { Locator, Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noDashes, ready, setFilter, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());

const WEEKDAY = 'Weekday cohort';
const WEEKEND = 'Weekend cohort';
/** The status words a class week can show while it is still to come (WEEK_STATUS in app/src/lib/status.ts). */
const UPCOMING_WORDS = [
  'Confirmed',
  'Waiting for an answer',
  'Needs instructor',
  'Proposed time',
  'Not asked yet',
  'Setup incomplete',
  'Paused',
];
/** The board's status codes and the words people read (the others read as their code). */
const WORD: Record<string, string> = { Waiting: 'Waiting for an answer' };

const chips = (page: Page) => page.getByRole('list', { name: 'Chosen filters' });
const filterButton = (page: Page, name: string) =>
  page.getByRole('group', { name: 'Filters' }).getByRole('button', { name, exact: true });

async function texts(rows: Locator, cell: number) {
  return (await rows.locator(`td:nth-child(${cell})`).allInnerTexts()).map((t) => t.trim());
}

test('Upcoming classes: filter by cohort and status, the choices stay after a reload, and Clear all', async ({
  page,
}) => {
  await page.goto('/classes');
  await ready(page);
  // The first row of each class week has the button that opens it, the cohort and the status.
  const weeks = page
    .locator('tbody tr')
    .filter({ has: page.getByRole('button', { name: /^Open / }) });
  const total = await weeks.count();
  expect(total).toBeGreaterThan(1);
  await expect(chips(page)).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Clear all' })).toHaveCount(0);

  // One cohort: only its class weeks.
  await setFilter(page, 'Cohort', [WEEKDAY]);
  await expect(
    chips(page).getByRole('button', { name: `Remove ${WEEKDAY}`, exact: true }),
  ).toBeVisible();
  const weekday = await weeks.count();
  expect(weekday).toBeGreaterThan(0);
  expect(weekday).toBeLessThan(total);
  for (const t of await weeks.allInnerTexts()) {
    expect(t).toContain(WEEKDAY);
    expect(t).not.toContain(WEEKEND);
  }

  // And one status it has (AND across fields): only its class weeks with that status.
  const status = (await texts(weeks, 4)).find((t) => UPCOMING_WORDS.includes(t));
  expect(status, 'a status word on a class week of the weekday cohort').toBeTruthy();
  await setFilter(page, 'Status', [status!]);
  const both = await weeks.count();
  expect(both).toBeGreaterThan(0);
  expect(both).toBeLessThanOrEqual(weekday);
  const statusCell = new RegExp(`^${status}(, at risk)?$`);
  for (const t of await texts(weeks, 4)) expect(t).toMatch(statusCell);
  for (const t of await weeks.allInnerTexts()) expect(t).toContain(WEEKDAY);
  await expect(
    chips(page).getByRole('button', { name: `Remove ${status}`, exact: true }),
  ).toBeVisible();
  await a11y(page, 'Upcoming classes with filters');
  await noDashes(page, 'Upcoming classes with filters');

  // Remembered for this person after a reload.
  await page.reload();
  await ready(page);
  await expect(filterButton(page, 'Cohort (1)')).toBeVisible();
  await expect(filterButton(page, 'Status (1)')).toBeVisible();
  await expect(
    chips(page).getByRole('button', { name: `Remove ${WEEKDAY}`, exact: true }),
  ).toBeVisible();
  await expect(
    chips(page).getByRole('button', { name: `Remove ${status}`, exact: true }),
  ).toBeVisible();
  await expect(weeks).toHaveCount(both);

  // Two cohorts are OR: at least as many; removing one chip goes back.
  await setFilter(page, 'Cohort', [WEEKDAY, WEEKEND]);
  expect(await weeks.count()).toBeGreaterThanOrEqual(both);
  await chips(page)
    .getByRole('button', { name: `Remove ${WEEKEND}`, exact: true })
    .click();
  await expect(weeks).toHaveCount(both);
  await expect(filterButton(page, 'Cohort (1)')).toBeVisible();

  // The list of a field, open: labelled checkboxes, and it passes the checks.
  await filterButton(page, 'Cohort (1)').click();
  const list = page.getByRole('dialog', { name: 'Cohort', exact: true });
  await expect(list.getByRole('checkbox', { name: WEEKDAY, exact: true })).toBeChecked();
  await expect(list.getByRole('checkbox', { name: WEEKEND, exact: true })).not.toBeChecked();
  await a11y(page, 'the Cohort filter list on Upcoming classes');
  await noDashes(page, 'the Cohort filter list on Upcoming classes');
  await page.keyboard.press('Escape');
  await expect(list).toHaveCount(0);

  // Clear all: every class week again, and nothing is remembered.
  await page.getByRole('button', { name: 'Clear all', exact: true }).click();
  await expect(chips(page)).toHaveCount(0);
  await expect(weeks).toHaveCount(total);
  await page.reload();
  await ready(page);
  await expect(filterButton(page, 'Cohort')).toBeVisible();
  await expect(filterButton(page, 'Status')).toBeVisible();
  await expect(weeks).toHaveCount(total);
});

test('Schedule board: filter by cohort and status, the choices stay after a reload, and Clear all', async ({
  page,
}) => {
  // What the board shows comes from schedule_board: the expected class weeks are counted from its answer.
  const answer = page.waitForResponse((r) => r.url().includes('/rpc/schedule_board') && r.ok());
  await page.goto('/board');
  const board = (await (await answer).json()) as {
    weeks: { cohort: string | null; status: string }[];
  };
  await ready(page);
  await page.getByRole('button', { name: 'List', exact: true }).click();
  const rows = page.locator('main table tbody tr');
  await expect(rows).toHaveCount(board.weeks.length);

  const mine = board.weeks.filter((w) => w.cohort === WEEKDAY);
  expect(mine.length, 'class weeks of the weekday cohort in the weeks shown').toBeGreaterThan(0);
  expect(mine.length).toBeLessThan(board.weeks.length);
  // The status most of its class weeks have.
  const byStatus = new Map<string, number>();
  for (const w of mine) byStatus.set(w.status, (byStatus.get(w.status) ?? 0) + 1);
  const [code, expected] = [...byStatus.entries()].sort((a, b) => b[1] - a[1])[0]!;
  const word = WORD[code] ?? code;

  await setFilter(page, 'Cohort', [WEEKDAY]);
  await expect(rows).toHaveCount(mine.length);
  for (const t of await texts(rows, 2)) expect(t).toBe(WEEKDAY);
  await setFilter(page, 'Status', [word]);
  await expect(rows).toHaveCount(expected);
  for (const t of await texts(rows, 2)) expect(t).toBe(WEEKDAY);
  for (const t of await texts(rows, 3)) expect(t).toContain(word);
  await expect(
    chips(page).getByRole('button', { name: `Remove ${WEEKDAY}`, exact: true }),
  ).toBeVisible();
  await expect(
    chips(page).getByRole('button', { name: `Remove ${word}`, exact: true }),
  ).toBeVisible();

  // By cohort shows only the chosen cohort's column.
  await page.getByRole('button', { name: 'By cohort', exact: true }).click();
  const columns = page.locator('main thead th[scope="col"]');
  await expect(columns).toHaveCount(1);
  await expect(columns.first()).toContainText(WEEKDAY);
  await page.getByRole('button', { name: 'List', exact: true }).click();

  // The list of a field, open, passes the checks.
  await filterButton(page, 'Status (1)').click();
  const list = page.getByRole('dialog', { name: 'Status', exact: true });
  await expect(list.getByRole('checkbox', { name: word, exact: true })).toBeChecked();
  await a11y(page, 'the Status filter list on the board');
  await noDashes(page, 'the Status filter list on the board');
  await page.keyboard.press('Escape');
  await expect(list).toHaveCount(0);

  // Remembered for this person after a reload, with the List view.
  await page.reload();
  await ready(page);
  await expect(filterButton(page, 'Cohort (1)')).toBeVisible();
  await expect(filterButton(page, 'Status (1)')).toBeVisible();
  await expect(page.getByRole('button', { name: 'List', exact: true })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(rows).toHaveCount(expected);
  await a11y(page, 'the board with filters');
  await noDashes(page, 'the board with filters');

  // Clear all: every class week again, and nothing is remembered.
  await page.getByRole('button', { name: 'Clear all', exact: true }).click();
  await expect(chips(page)).toHaveCount(0);
  await expect(rows).toHaveCount(board.weeks.length);
  await page.reload();
  await ready(page);
  await expect(filterButton(page, 'Cohort')).toBeVisible();
  await expect(filterButton(page, 'Status')).toBeVisible();
  await expect(rows).toHaveCount(board.weeks.length);
});
