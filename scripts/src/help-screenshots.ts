// Pictures for the in app Help guides (app/public/help/*.png), light theme, desktop width, with
// numbered markers and highlight boxes. Run through `npm run help:screenshots` (it loads demo data
// first and puts the local data back afterwards). Needs the local stack and the app on :5173.
//
//   npm run help:screenshots            # every picture
//   npm run help-shots -w scripts -- plan   # only pictures whose name starts with "plan"
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { chromium, type Locator, type Page } from 'playwright';
import pg from 'pg';
import { chromePath, localKeys, signInLink } from './browser.ts';

const ROOT = join(import.meta.dirname, '..', '..');
const OUT = join(ROOT, 'app', 'public', 'help');
const APP = process.env.APP_URL ?? 'http://localhost:5173';
const EMAIL = process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com';
const DB = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';

type Mark = (p: Page) => Locator;
type Pic = {
  file: string;
  path: string;
  act?: (p: Page) => Promise<void>;
  marks?: Mark[];
  /** Picture of one part of the page instead of the whole window. */
  clip?: Mark;
  before?: () => Promise<void>;
  after?: () => Promise<void>;
};

const button = (name: RegExp) => (p: Page) => p.getByRole('button', { name }).first();
const click = (name: RegExp) => async (p: Page) => {
  await button(name)(p).click();
  await p.waitForTimeout(800);
};
const sql = async (q: string, params: unknown[] = []) => {
  const c = new pg.Client({ connectionString: DB });
  await c.connect();
  try {
    await c.query(q, params);
  } finally {
    await c.end();
  }
};

const PICS: Pic[] = [
  {
    file: 'first-sign-in-discord.png',
    path: '/',
    before: () =>
      sql(
        'update public.team_member set discord_prompt_dismissed_at = null, version = version where email = $1',
        [EMAIL],
      ),
    after: () =>
      sql(
        'update public.team_member set discord_prompt_dismissed_at = now(), version = version where email = $1',
        [EMAIL],
      ),
    marks: [(p) => p.getByLabel('Your Discord user ID'), button(/^save$/i)],
  },
  {
    file: 'instructors-list.png',
    path: '/setup/instructors',
    marks: [button(/add instructor/i), (p) => p.getByText('Status', { exact: true }).first()],
  },
  {
    file: 'module-new.png',
    path: '/setup/modules/new',
    marks: [(p) => p.getByRole('list', { name: 'Steps' })],
  },
  {
    file: 'domains-drawer.png',
    path: '/setup/domains',
    act: async (p) => {
      await p.locator('tbody tr').first().click();
      await p.waitForTimeout(800);
    },
    marks: [(p) => p.getByRole('heading', { name: 'Escalation contacts' })],
  },
  {
    file: 'plan-classes.png',
    path: '/classes',
    act: click(/plan classes/i),
    marks: [
      (p) => p.getByRole('dialog').getByRole('combobox').first(),
      (p) => p.getByText('Date of the first class', { exact: true }),
      button(/show the plan/i),
    ],
  },
  {
    file: 'automation.png',
    path: '/settings/automation',
    marks: [
      (p) => p.getByLabel('Settings for'),
      (p) => p.getByRole('button', { name: /^Standard/ }),
    ],
  },
  {
    file: 'timeline.png',
    path: '/settings/automation',
    clip: (p) => p.locator('section', { hasText: 'What happens before a class' }).first(),
  },
  {
    file: 'instructor-requests.png',
    path: '/requests',
    marks: [
      (p) => p.getByRole('button', { name: /^asking now/i }),
      (p) => p.getByRole('button', { name: /more options/i }).first(),
    ],
  },
  {
    file: 'home-tasks.png',
    path: '/',
    marks: [
      button(/i.m on it/i),
      (p) => p.getByLabel('Assign to a team member').first(),
      button(/mark done/i),
    ],
  },
  {
    file: 'help-request.png',
    path: '/',
    act: click(/open help request/i),
    marks: [button(/i.m on it/i)],
  },
  {
    file: 'class-drawer.png',
    path: '/classes',
    act: async (p) => {
      await p.locator('tbody tr').first().click();
      await p.waitForTimeout(800);
    },
    marks: [button(/release instructor/i), button(/^change time$/i)],
  },
  {
    file: 'practice-class.png',
    path: '/settings/testing',
    act: async (p) => {
      await button(/run a practice class/i)(p).click();
      await p.getByText(/every stage worked|some stages did not work/i).waitFor({ timeout: 30000 });
    },
    clip: (p) => p.locator('section', { hasText: 'Run a practice class' }).first(),
  },
  {
    file: 'pause-menu.png',
    path: '/',
    act: click(/your account and theme/i),
    marks: [(p) => p.getByRole('menuitem', { name: /pause all messages/i })],
  },
  {
    file: 'activity.png',
    path: '/activity',
    marks: [
      (p) => p.getByText('From', { exact: true }).first(),
      (p) => p.getByRole('button', { name: /show details/i }).first(),
    ],
  },
  {
    file: 'connections.png',
    path: '/settings/connections',
    clip: (p) => p.locator('section', { hasText: 'Connection health' }).first(),
  },
];

/** Draw a highlight box and a numbered marker on top of each element (positions are on screen). */
async function drawMarks(page: Page, marks: Mark[]) {
  let n = 0;
  for (const m of marks) {
    n += 1;
    const box = await m(page)
      .boundingBox()
      .catch(() => null);
    if (!box) {
      console.warn(`    marker ${n} not found`);
      continue;
    }
    await page.evaluate(
      ({ box, n }) => {
        const pad = 4;
        const frame = document.createElement('div');
        frame.setAttribute('data-help-mark', '');
        Object.assign(frame.style, {
          position: 'fixed',
          left: `${box.x - pad}px`,
          top: `${box.y - pad}px`,
          width: `${box.width + pad * 2}px`,
          height: `${box.height + pad * 2}px`,
          border: '3px solid #e5534b',
          borderRadius: '8px',
          zIndex: '2147483646',
          pointerEvents: 'none',
        });
        const dot = document.createElement('div');
        dot.setAttribute('data-help-mark', '');
        dot.textContent = String(n);
        Object.assign(dot.style, {
          position: 'fixed',
          left: `${box.x - pad - 14}px`,
          top: `${box.y - pad - 14}px`,
          width: '26px',
          height: '26px',
          borderRadius: '13px',
          background: '#e5534b',
          color: '#fff',
          font: '700 14px/26px Segoe UI, Arial, sans-serif',
          textAlign: 'center',
          zIndex: '2147483647',
          pointerEvents: 'none',
        });
        document.body.append(frame, dot);
      },
      { box, n },
    );
  }
}

async function main() {
  const only = process.argv.slice(2);
  const pics = only.length ? PICS.filter((p) => only.some((o) => p.file.startsWith(o))) : PICS;
  const { api, secret } = localKeys();
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium
    .launch()
    .catch(() => chromium.launch({ executablePath: chromePath() }));
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    colorScheme: 'light',
  });
  await ctx.addInitScript(() => localStorage.setItem('ik-theme', 'light'));
  const page = await ctx.newPage();
  await page.goto(await signInLink(api, secret, EMAIL, APP));
  await page
    .waitForURL((u) => u.toString().startsWith(APP) && !u.hash.includes('access_token'), {
      timeout: 15000,
    })
    .catch(() => {});
  for (const pic of pics) {
    try {
      await pic.before?.();
      await page.goto(APP + pic.path);
      await page
        .waitForFunction(() => !document.querySelector('.animate-pulse'), null, { timeout: 8000 })
        .catch(() => {});
      await page.waitForTimeout(700);
      await pic.act?.(page);
      if (pic.marks) await drawMarks(page, pic.marks);
      const file = join(OUT, pic.file);
      if (pic.clip) await pic.clip(page).screenshot({ path: file });
      else await page.screenshot({ path: file });
      console.log(`  ✓ ${pic.file}`);
    } catch (e) {
      console.warn(`  ! ${pic.file}: ${(e as Error).message.split('\n')[0]}`);
      process.exitCode = 1;
    } finally {
      await pic.after?.().catch(() => {});
      await page.keyboard.press('Escape').catch(() => {});
    }
  }
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
