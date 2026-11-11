// Screenshots of every page, drawer and dialog in light and dark themes, desktop and mobile.
//   npm run screenshots -w scripts                 # everything into docs/screenshots/
//   npm run screenshots -w scripts -- home classes # only shots whose name starts with these
// Needs the separate test stack (npm run test-stack -w scripts -- up, then npm run demo -w scripts -- load)
// and an app server for it on http://localhost:5174 (see scripts/src/help-screenshots.ts).
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { chromium, type Page } from 'playwright';
import { chromePath, localKeys, signInLink } from './browser.ts';
import pg from 'pg';

const ROOT = join(import.meta.dirname, '..', '..');
const OUT = join(ROOT, 'docs', 'screenshots');
const APP = process.env.APP_URL ?? 'http://localhost:5174';
const EMAIL = process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com';
const DB =
  process.env.TEST_DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55522/postgres';
const DEMO_MODULE = 'Screenshot module';

/** Remove modules made by the new module flow shots, so later shots do not show them. */
async function removeDemoModules() {
  const c = new pg.Client({ connectionString: DB });
  await c.connect();
  await c.query('delete from public.module where name = $1', [DEMO_MODULE]);
  await c.end();
}

type Shot = {
  name: string;
  path: string;
  act?: (p: Page) => Promise<void>;
  /** Only at this width (for example the mobile menu). */
  width?: 'desktop' | 'mobile';
};

const click = (text: string | RegExp) => async (p: Page) => {
  await p.getByRole('button', { name: text }).first().click();
  await p.waitForTimeout(700);
};
const menuItem = (text: string | RegExp) => async (p: Page) => {
  await p
    .getByRole('button', { name: /more options/i })
    .first()
    .click();
  await p.waitForTimeout(300);
  await p.getByRole('menuitem', { name: text }).first().click();
  await p.waitForTimeout(700);
};
const clickRow = (selector: string) => async (p: Page) => {
  await p.locator(selector).first().click();
  await p.waitForTimeout(800);
};

/** Wait until the page has drawn its data: no loading skeletons, then a short pause. */
async function settle(p: Page) {
  await p
    .waitForFunction(() => !document.querySelector('.animate-pulse'), null, { timeout: 8000 })
    .catch(() => {});
  await p.waitForTimeout(500);
}

const steps =
  (...fns: ((p: Page) => Promise<void>)[]) =>
  async (p: Page) => {
    for (const f of fns) await f(p);
  };
const fill = (label: string | RegExp, value: string) => async (p: Page) => {
  await p.getByLabel(label).first().fill(value);
};
const tab = (name: string | RegExp) => async (p: Page) => {
  await p.getByRole('tab', { name }).first().click();
  await p.waitForTimeout(600);
};
/** The new module flow: step 1 saves a module, so run this only on demo data. */
const newModule = (to: number) =>
  steps(
    fill(/^name/i, DEMO_MODULE),
    click(/save and continue/i),
    ...Array.from({ length: Math.max(0, to - 2) }, () => click(/^continue$/i)),
  );

export const SHOTS: Shot[] = [
  { name: 'home', path: '/' },
  { name: 'home-help-request', path: '/', act: click(/open help request/i) },
  { name: 'shell-domain-switcher', path: '/', act: click(/choose a domain/i), width: 'desktop' },
  {
    name: 'shell-user-menu',
    path: '/',
    act: click(/your account and theme/i),
    width: 'desktop',
  },
  { name: 'shell-mobile-menu', path: '/', act: click(/open menu/i), width: 'mobile' },
  { name: 'classes', path: '/classes' },
  { name: 'classes-plan-dialog', path: '/classes', act: click(/plan classes/i) },
  { name: 'classes-add-class', path: '/classes', act: click(/add one class/i) },
  { name: 'classes-class-drawer', path: '/classes', act: clickRow('tbody tr') },
  {
    name: 'classes-cancel-confirm',
    path: '/classes',
    act: steps(clickRow('tbody tr'), click(/^cancel class week$/i)),
  },
  { name: 'requests', path: '/requests' },
  {
    name: 'requests-choose-who',
    path: '/requests',
    act: menuItem(/change the order for this class week/i),
  },
  { name: 'requests-ask-person', path: '/requests', act: menuItem(/ask a specific person/i) },
  {
    name: 'requests-more-menu',
    path: '/requests',
    act: click(/more options/i),
  },
  { name: 'requests-ask-next-confirm', path: '/requests', act: click(/ask the next instructor/i) },
  { name: 'requests-release-confirm', path: '/requests', act: click(/^release$/i) },
  { name: 'modules', path: '/setup/modules' },
  { name: 'module-detail', path: '/setup/modules', act: clickRow('tbody tr') },
  {
    name: 'module-detail-order',
    path: '/setup/modules',
    act: steps(clickRow('tbody tr'), tab(/instructor order/i)),
  },
  {
    name: 'module-detail-times',
    path: '/setup/modules',
    act: steps(clickRow('tbody tr'), tab(/class times/i)),
  },
  { name: 'modules-new-1-details', path: '/setup/modules/new' },
  { name: 'modules-new-1-errors', path: '/setup/modules/new', act: click(/save and continue/i) },
  { name: 'modules-new-2-times', path: '/setup/modules/new', act: newModule(2) },
  { name: 'modules-new-3-order', path: '/setup/modules/new', act: newModule(3) },
  {
    name: 'modules-new-3-add-instructor',
    path: '/setup/modules/new',
    act: steps(newModule(3), click(/add new instructor/i)),
  },
  { name: 'modules-new-4-owners', path: '/setup/modules/new', act: newModule(4) },
  { name: 'modules-new-5-materials', path: '/setup/modules/new', act: newModule(5) },
  { name: 'modules-new-6-review', path: '/setup/modules/new', act: newModule(6) },
  { name: 'instructors', path: '/setup/instructors' },
  { name: 'instructors-add-drawer', path: '/setup/instructors', act: click(/add instructor/i) },
  { name: 'instructors-edit-drawer', path: '/setup/instructors', act: clickRow('tbody tr') },
  { name: 'team', path: '/setup/team' },
  { name: 'team-drawer', path: '/setup/team', act: clickRow('tbody tr') },
  { name: 'domains', path: '/setup/domains' },
  { name: 'domains-create', path: '/setup/domains', act: click(/create domain/i) },
  { name: 'domains-drawer', path: '/setup/domains', act: clickRow('tbody tr') },
  { name: 'settings-automation', path: '/settings/automation' },
  { name: 'settings-automation-help', path: '/settings/automation', act: tab(/help/i) },
  { name: 'settings-testing', path: '/settings/testing' },
  {
    name: 'settings-testing-practice',
    path: '/settings/testing',
    act: steps(click(/run a practice class/i), async (p) => p.waitForTimeout(4000)),
  },
  { name: 'settings-messages', path: '/settings/messages' },
  {
    name: 'settings-messages-edit',
    path: '/settings/messages',
    act: click(/^request to teach/i),
  },
  { name: 'settings-testing-go-live', path: '/settings/testing', act: click(/^go live$/i) },
  { name: 'settings-connections', path: '/settings/connections' },
  {
    name: 'settings-connections-pause',
    path: '/settings/connections',
    act: click(/^pause all messages$/i),
  },
  { name: 'help', path: '/help' },
  { name: 'help-guide', path: '/help/planning-classes' },
  { name: 'activity', path: '/activity' },
  { name: 'activity-details', path: '/activity', act: click(/show details/i) },
];

async function main() {
  const only = process.argv.slice(2);
  const shots = only.length ? SHOTS.filter((s) => only.some((o) => s.name.startsWith(o))) : SHOTS;
  const { api, secret } = localKeys();
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium
    .launch()
    .catch(() => chromium.launch({ executablePath: chromePath() }));
  for (const theme of ['light', 'dark'] as const) {
    for (const vp of [
      { name: 'desktop', width: 1440, height: 900 },
      { name: 'mobile', width: 390, height: 844 },
    ]) {
      const ctx = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        colorScheme: theme,
      });
      await ctx.addInitScript((t) => localStorage.setItem('ik-theme', t), theme);
      const page = await ctx.newPage();
      await page.goto(await signInLink(api, secret, EMAIL, APP));
      await page
        .waitForURL((u) => u.toString().startsWith(APP) && !u.hash.includes('access_token'), {
          timeout: 15000,
        })
        .catch(() => {});
      await page.waitForTimeout(1500);
      await page.goto(APP + '/');
      await settle(page);
      for (const s of shots.filter((x) => !x.width || x.width === vp.name)) {
        // Move inside the app (no reload): much faster than loading every page from scratch.
        // The same address again needs a real load so the page starts fresh (new module flow).
        if (new URL(page.url()).pathname === s.path) await page.goto(APP + s.path);
        else
          await page.evaluate((path) => {
            window.history.pushState({}, '', path);
            window.dispatchEvent(new PopStateEvent('popstate'));
            window.scrollTo(0, 0);
          }, s.path);
        await settle(page);
        try {
          if (s.act) await s.act(page);
        } catch (e) {
          console.warn(
            `  ! ${s.name} (${theme}, ${vp.name}): ${(e as Error).message.split('\n')[0]}`,
          );
        }
        const file = join(OUT, `${s.name}-${theme}-${vp.name}.png`);
        if (s.act) {
          await page.screenshot({ path: file });
        } else {
          // Grow the window to the page height so the sticky sidebar is drawn full length.
          const h = await page.evaluate(() => document.documentElement.scrollHeight);
          await page.setViewportSize({ width: vp.width, height: Math.max(vp.height, h) });
          await page.waitForTimeout(150);
          await page.screenshot({ path: file });
          await page.setViewportSize({ width: vp.width, height: vp.height });
        }
        console.log(`  ✓ ${s.name}-${theme}-${vp.name}.png`);
        if (s.name.startsWith('modules-new')) await removeDemoModules();
        await page.keyboard.press('Escape').catch(() => {});
        await page.keyboard.press('Escape').catch(() => {});
      }
      await ctx.close();
    }
  }
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
