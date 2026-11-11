// Visits every route and clicks every enabled control, including the controls inside each drawer,
// dialog and menu it opens. Confirmation questions are answered "no" (Escape), so nothing is
// deleted on purpose, but quick actions do run. Any console error, page error or server error fails.
// A rule refusing a click (a 4xx answer from a database function, shown to the user as a message)
// is expected and listed in the report instead.
import type { Locator, Page } from '@playwright/test';
import { loadDemoData, ready, sql, test } from './fixtures.ts';

const CONTROLS =
  'button, [role="tab"], [role="switch"], [role="checkbox"], [role="menuitem"], [role="menuitemradio"], summary, input[type="checkbox"], select, a[href^="/"]';
/** Never clicked: these end the session or need typed confirmation by design. */
// Archive, restore and delete change the test data for every later page; the scenario tests cover them
// (decision 260).
const SKIP =
  /sign out|reset sandbox data|^archive$|^restore$|delete permanently|restore class week/i;
/** Set E2E_VERBOSE=1 to print each click with the time it took. */
const verbose = process.env.E2E_VERBOSE === '1';
let last = Date.now();
const trace = (what: string) => {
  if (verbose) console.log(`${Date.now() - last}ms ${what}`);
  last = Date.now();
};
const LAYER = '[role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"]';

const ROUTES = [
  '/',
  '/classes',
  '/requests',
  '/setup/modules',
  '/setup/modules/new',
  'MODULE',
  'MODULE?tab=times',
  'MODULE?tab=order',
  'MODULE?tab=owners',
  'MODULE?tab=operations',
  'MODULE?tab=materials',
  'MODULE?tab=next',
  '/setup/instructors',
  '/setup/team',
  '/setup/domains',
  '/settings/automation',
  '/settings/messages',
  '/settings/testing',
  '/settings/connections',
  '/activity',
  '/help',
];

// Each page is its own test, so one problem does not hide the others. Clicking everything takes time.
test.describe.configure({ mode: 'default', timeout: 15 * 60_000 });
test.afterAll(() => loadDemoData());

async function label(el: Locator) {
  return (
    (await el.evaluate(
      (n: Element) =>
        n.getAttribute('aria-label') ||
        (n as HTMLElement).innerText?.trim().split('\n')[0] ||
        n.getAttribute('title') ||
        n.tagName.toLowerCase(),
    )) ?? ''
  ).slice(0, 60);
}

async function settle(page: Page) {
  await page.waitForTimeout(250);
  await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {});
}

async function closeLayers(page: Page) {
  for (let k = 0; k < 4 && (await page.locator(LAYER).count()) > 0; k++) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
  }
}

/** Click one control. Selects get their second option; everything else a normal click. */
async function press(page: Page, el: Locator) {
  const tag = await el.evaluate((n: Element) => n.tagName.toLowerCase());
  if (tag === 'select') {
    const values = await el.evaluate((n: Element) =>
      Array.from((n as HTMLSelectElement).options).map((o) => o.value),
    );
    if (values.length > 1) await el.selectOption(values[1]!);
    return;
  }
  await el.click({ timeout: 5_000 });
}

async function usable(el: Locator) {
  return (
    (await el.count()) > 0 &&
    (await el.isVisible().catch(() => false)) &&
    (await el.isEnabled().catch(() => false))
  );
}

/** Click every control inside the open drawer, dialog or menu, reopening it when needed. */
async function crawlLayer(page: Page, url: string, reopen: () => Promise<void>, done: string[]) {
  const layer = () => page.locator(LAYER).last();
  const total = await layer().locator(CONTROLS).count();
  for (let i = 0; i < Math.min(total, 60); i++) {
    if (page.url() !== url || (await page.locator(LAYER).count()) === 0) {
      if (page.url() !== url) await page.goto(url);
      await ready(page);
      await reopen();
      await settle(page);
      if ((await page.locator(LAYER).count()) === 0) return;
    }
    const el = layer().locator(CONTROLS).nth(i);
    if (!(await usable(el))) continue;
    const name = await label(el);
    if (SKIP.test(name)) continue;
    const before = await page.locator(LAYER).count();
    await press(page, el).catch(() => {});
    await settle(page);
    // A confirmation question opened on top: answer no.
    if ((await page.locator(LAYER).count()) > before) {
      await page.keyboard.press('Escape');
      await page.waitForTimeout(150);
    }
    done.push(`  inside: ${name}`);
    trace(`  inside: ${name}`);
  }
}

for (const route of ROUTES) {
  test(`click everything on ${route}`, async ({ page, problems }) => {
    problems.allow.push(
      /HTTP 4\d\d: POST .*\/rest\/v1\/rpc\//,
      /Failed to load resource: the server responded with a status of 4\d\d/,
    );
    let url = route;
    if (route.startsWith('MODULE')) {
      const [m] = await sql<{ id: string }>(
        `select m.id from public.module m join public.domain d on d.id = m.domain_id
          where d.name = 'Backend' order by m.name limit 1`,
      );
      url = route.replace('MODULE', `/setup/modules/${m!.id}`);
    }
    await page.goto(url);
    await ready(page);
    const full = page.url();
    const scope = page.locator('main');
    const total = await scope.locator(CONTROLS).count();
    const done: string[] = [];
    // Rows repeat the same buttons (each opens the same kind of drawer): every button is
    // clicked, but the controls inside a drawer are clicked the first time only.
    const opened = new Set<string>();
    for (let i = 0; i < total; i++) {
      if (page.url() !== full || (await page.locator(LAYER).count()) > 0) {
        await closeLayers(page);
        if (page.url() !== full) await page.goto(full);
        await ready(page);
      }
      const el = scope.locator(CONTROLS).nth(i);
      if (!(await usable(el))) continue;
      const name = await label(el);
      if (SKIP.test(name)) continue;
      await press(page, el).catch(() => {});
      await settle(page);
      done.push(name);
      trace(name);
      // The same kind of control (same element and styling) opens the same kind of drawer.
      const kind = `${await el.evaluate((n: Element) => `${n.tagName}.${n.className}`).catch(() => name)}|${
        (await page
          .locator(LAYER)
          .last()
          .getAttribute('role')
          .catch(() => '')) ?? ''
      }`;
      if ((await page.locator(LAYER).count()) > 0 && page.url() === full && !opened.has(kind)) {
        opened.add(kind);
        await crawlLayer(
          page,
          full,
          async () => {
            const again = scope.locator(CONTROLS).nth(i);
            if (await usable(again)) await press(page, again).catch(() => {});
          },
          done,
        );
      }
    }
    test.info().annotations.push({ type: 'clicked', description: done.join('\n') });
  });
}

test('click everything in the sidebar and the account menu', async ({ page, problems }) => {
  problems.allow.push(/HTTP 4\d\d: POST .*\/rest\/v1\/rpc\//);
  await page.goto('/');
  await ready(page);
  const mobile = (page.viewportSize()?.width ?? 1280) < 768;
  const open = async () => {
    if (mobile) await page.getByRole('button', { name: 'Open menu' }).click();
  };
  await open();
  const side = page.locator('aside').first();
  const done: string[] = [];
  const total = await side.locator(CONTROLS).count();
  for (let i = 0; i < total; i++) {
    await closeLayers(page);
    if (mobile && !(await side.isVisible())) await open();
    const el = side.locator(CONTROLS).nth(i);
    if (!(await usable(el))) continue;
    const name = await label(el);
    if (SKIP.test(name)) continue;
    await press(page, el).catch(() => {});
    await settle(page);
    done.push(name);
    if ((await page.locator('[role="menu"]').count()) > 0) {
      await crawlLayer(
        page,
        page.url(),
        async () => {
          if (mobile && !(await side.isVisible())) await open();
          const again = side.locator(CONTROLS).nth(i);
          if (await usable(again)) await press(page, again).catch(() => {});
        },
        done,
      );
    }
  }
  test.info().annotations.push({ type: 'clicked', description: done.join('\n') });
});
