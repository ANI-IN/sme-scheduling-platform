// The Legend and help panel (owner, 24 November 2026, decision 344) on the Schedule board and Upcoming classes: it
// opens the first time, then remembers each person's choice; it slides in over the board without moving it; the
// Legend can be searched and narrowed to what the board shows; a badge's "What is this?" opens it at that item.
import type { Page } from '@playwright/test';
import { a11y, expect, loadDemoData, noDashes, ready, test } from './fixtures.ts';
import { layoutOk } from './layout.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
// A first visit: nothing remembered yet.
test.use({ helpPanel: 'unset' });

const panelOf = (page: Page) => page.getByRole('dialog', { name: 'Legend and help' });
const helpButton = (page: Page) =>
  page.getByRole('button', { name: 'Legend and help', exact: true });

async function openBoard(page: Page) {
  await page.goto('/board');
  await ready(page);
}

/** Where the board is and how big, with the page's scroll position: none of it may change with the panel. */
async function boardBox(page: Page) {
  const read = () =>
    page.evaluate(() => {
      const table = document.querySelector('main table')!;
      const t = table.getBoundingClientRect();
      const cell = document.querySelector('main table button')!.getBoundingClientRect();
      // Every box that scrolls around the board, the page included.
      const scrolls: number[] = [window.scrollX, window.scrollY];
      for (let e: Element | null = table.parentElement; e; e = e.parentElement)
        if (e.scrollTop || e.scrollLeft) scrolls.push(e.scrollLeft, e.scrollTop);
      return {
        table: [t.x, t.y, t.width, t.height].map(Math.round),
        cell: [cell.x, cell.y, cell.width, cell.height].map(Math.round),
        scrolls: scrolls.map(Math.round),
      };
    });
  // Wait until nothing is still scrolling or animating: two readings 300 ms apart agree.
  let last = await read();
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(300);
    const now = await read();
    if (JSON.stringify(now) === JSON.stringify(last)) return now;
    last = now;
  }
  return last;
}

test('the panel opens the first time, with every status and badge in one line each', async ({
  page,
}) => {
  await openBoard(page);
  const panel = panelOf(page);
  await expect(panel).toBeVisible();
  await expect(helpButton(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(panel.getByRole('tab', { name: 'Legend' })).toHaveAttribute('aria-selected', 'true');
  for (const group of ['Statuses', 'Badges on a class week'])
    await expect(panel.getByRole('region', { name: group })).toBeVisible();
  for (const label of [
    'Waiting for an answer',
    'Needs instructor',
    'Clash',
    'Sooner class first',
    'Cohort holiday',
    'Shared class',
    'Break',
    'Check needed',
  ])
    await expect(panel.locator('li').filter({ hasText: label }).first()).toBeVisible();
  // One line each: a badge and its meaning.
  const items = panel.locator('li[id^="legend-item-"]');
  expect(await items.count()).toBeGreaterThan(50);
  await expect(items.locator('[data-badge]')).toHaveCount(await items.count());
  await a11y(page, 'legend and help panel');
  await noDashes(page, 'legend and help panel');
  await layoutOk(page, 'legend and help panel');
});

test('close with the X, Escape or the button; focus returns to the button; the choice is remembered', async ({
  page,
}) => {
  await openBoard(page);
  const panel = panelOf(page);
  await expect(panel).toBeVisible();
  // The X.
  await panel.getByRole('button', { name: 'Close the legend and help' }).click();
  await expect(panel).toHaveCount(0);
  await expect(helpButton(page)).toBeFocused();
  await expect(helpButton(page)).toHaveAttribute('aria-expanded', 'false');
  await page.reload();
  await ready(page);
  await expect(panel).toHaveCount(0);
  // The button opens it and moves the focus into it; Escape closes it.
  await helpButton(page).click();
  await expect(panel).toBeVisible();
  await expect(panel.locator(':focus')).toHaveCount(1);
  await page.keyboard.press('Escape');
  await expect(panel).toHaveCount(0);
  await expect(helpButton(page)).toBeFocused();
  // The button closes it too, and opening it is remembered.
  await helpButton(page).click();
  await expect(panel).toBeVisible();
  await page.reload();
  await ready(page);
  await expect(panel).toBeVisible();
  await helpButton(page).click();
  await expect(panel).toHaveCount(0);
});

test('the board does not move or change size when the panel opens or closes, and a selection stays', async ({
  page,
}) => {
  await openBoard(page);
  if (await panelOf(page).isVisible()) await helpButton(page).click();
  await page.getByRole('button', { name: 'Select class weeks' }).click();
  const first = page.getByRole('button', { name: /^Select: Open / }).first();
  await first.click();
  await page.mouse.wheel(0, 300);
  const closed = await boardBox(page);
  await helpButton(page).click();
  await expect(panelOf(page)).toBeVisible();
  expect(await boardBox(page)).toEqual(closed);
  // The board under it still works: clicking it does not close the panel.
  await page.getByRole('heading', { name: 'Needs a decision' }).click();
  await expect(panelOf(page)).toBeVisible();
  await helpButton(page).click();
  await expect(panelOf(page)).toHaveCount(0);
  expect(await boardBox(page)).toEqual(closed);
  await expect(page.getByRole('button', { name: /^Selected: Open / })).toHaveCount(1);
});

test('search the legend, and Only what is on this board', async ({ page }) => {
  await openBoard(page);
  if (!(await panelOf(page).isVisible())) await helpButton(page).click();
  const panel = panelOf(page);
  await panel.getByRole('searchbox', { name: 'Search the legend' }).fill('holiday');
  const labels = () => panel.locator('li[id^="legend-item-"] [data-badge]').allInnerTexts();
  const found = await labels();
  expect(found).toEqual(expect.arrayContaining(['Holiday', 'Cohort holiday']));
  for (const line of await panel.locator('li[id^="legend-item-"]').allInnerTexts())
    expect(line.toLowerCase()).toContain('holiday');
  await panel.getByRole('searchbox', { name: 'Search the legend' }).fill('nothing like this');
  await expect(panel.getByText('Nothing matches. Try another word.')).toBeVisible();
  await panel.getByRole('searchbox', { name: 'Search the legend' }).fill('');
  await panel.getByRole('switch', { name: "Only what's on this board" }).click();
  const onBoard = new Set(
    (await page.locator('main [data-badge]').allInnerTexts()).map((t) => t.trim()),
  );
  const shown = (await labels()).map((t) => t.trim());
  expect(shown.length).toBeGreaterThan(0);
  expect(shown).toContain('Waiting for an answer');
  for (const l of shown) expect(onBoard.has(l), `${l} is on the board`).toBe(true);
  expect(shown).not.toContain('Merged into');
});

test("a badge's What is this? opens the panel on the Legend at that item", async ({ page }) => {
  await openBoard(page);
  if (await panelOf(page).isVisible()) await helpButton(page).click();
  await page
    .getByRole('button', { name: /^Open .*: Waiting for an answer/ })
    .first()
    .click();
  const drawer = page.getByRole('dialog').first();
  await drawer.getByRole('button', { name: 'What is Waiting for an answer?' }).click();
  const panel = panelOf(page);
  await expect(panel).toBeVisible();
  await expect(panel.getByRole('tab', { name: 'Legend' })).toHaveAttribute('aria-selected', 'true');
  const item = panel.locator('#legend-item-waitingforananswer');
  await expect(item).toBeFocused();
  await expect(item).toBeInViewport();
});

test('hover or keyboard focus on a class week shows what its status and badges mean', async ({
  page,
}) => {
  await openBoard(page);
  if (await panelOf(page).isVisible()) await helpButton(page).click();
  const cell = page.getByRole('button', { name: /^Open .*: Waiting for an answer/ }).first();
  await cell.focus();
  const tip = page.getByRole('tooltip');
  await expect(tip).toContainText(
    'Waiting for an answer: An instructor was asked and has not answered yet.',
  );
  await page.keyboard.press('Escape');
  await page.mouse.move(0, 0);
  await cell.hover();
  await expect(tip).toContainText('Waiting for an answer:');
});

test('on a phone the panel is a full height sheet with a Close button', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openBoard(page);
  if (!(await panelOf(page).isVisible())) await helpButton(page).click();
  const panel = panelOf(page);
  const box = await panel.boundingBox();
  expect(box).toMatchObject({ x: 0, y: 0, width: 390, height: 844 });
  await layoutOk(page, 'legend and help panel on a phone');
  await panel.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(panel).toHaveCount(0);
  await expect(helpButton(page)).toBeFocused();
});

test('Upcoming classes has the same panel, remembered on its own', async ({ page }) => {
  await page.goto('/classes');
  await ready(page);
  const panel = panelOf(page);
  await expect(panel).toBeVisible();
  await expect(panel.getByRole('tab')).toHaveText([
    'Legend',
    'How to read this page',
    'Page controls',
  ]);
  await panel.getByRole('switch', { name: "Only what's on this page" }).click();
  await expect(panel.locator('li[id^="legend-item-"]').first()).toBeVisible();
  await panel.getByRole('tab', { name: 'Page controls' }).click();
  await expect(panel.getByText('Plan classes', { exact: true })).toBeVisible();
  await a11y(page, 'Upcoming classes legend and help');
  await noDashes(page, 'Upcoming classes legend and help');
  await helpButton(page).click();
  await expect(panel).toHaveCount(0);
  await page.reload();
  await ready(page);
  await expect(panel).toHaveCount(0);
});
