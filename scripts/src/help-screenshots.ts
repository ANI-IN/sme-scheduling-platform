// Pictures for the in app Help guides (app/public/help/*.png), light theme, desktop width, with
// numbered markers and highlight boxes. Run through `npm run help:screenshots`: it starts the separate
// test stack, loads the test data, starts an app server on :5174 for it, and removes the stack afterwards.
//
//   npm run help:screenshots            # every picture
//   npm run help-shots -w scripts -- plan   # only pictures whose name starts with "plan"
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { chromium, type Locator, type Page } from 'playwright';
import pg from 'pg';
import { chromePath, localKeys, signInLink } from './browser.ts';

const ROOT = join(import.meta.dirname, '..', '..');
const OUT = join(ROOT, 'app', 'public', 'help');
const APP = process.env.APP_URL ?? 'http://localhost:5174';
const EMAIL = process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com';
const DB =
  process.env.TEST_DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55522/postgres';

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

/**
 * Made up Discord setup for the pictures: a server for Backend that is ready, its channels, and
 * usernames and channels for the test instructors (one not found, to show what that looks like).
 * Nothing is sent to Discord; the local data is put back after the pictures.
 */
const discordDemo = () =>
  sql(`
    insert into public.discord_server (id, name, refreshed_at, status, checked_at)
    values ('900000000000000001', 'Backend program', now(), 'Ready', now())
    on conflict (id) do update set name = excluded.name, refreshed_at = now(), status = 'Ready', checked_at = now();
    insert into public.discord_channel (id, server_id, name, category, position)
    select '9000000000000001' || n, '900000000000000001', 'test-instructor-' || chr(96 + n), '1-1', n
      from generate_series(1, 6) n
    union all select '900000000000000099', '900000000000000001', 'backend-alerts', null, 0
    on conflict (id) do nothing;
    update public.domain set discord_server_id = '900000000000000001', discord_status = 'Ready',
           discord_problem = null, discord_checked_at = now(), alert_discord_channel_id = '900000000000000099',
           version = version
     where name = 'Backend';
    update public.instructor set discord_username = 'test.instructor.' || lower(right(full_name, 1)), version = version
     where is_test;
    update public.instructor set discord_status = 'Found', discord_problem = null, discord_checked_at = now(),
           version = version
     where is_test and full_name <> 'Test Instructor E';
    update public.instructor set discord_status = 'NotFound', discord_checked_at = now(), version = version,
           discord_problem = 'Nobody with the username test.instructor.e is in Backend program. Check the spelling (lowercase, without @) and that they joined the server, then press Check Discord.'
     where full_name = 'Test Instructor E';
    delete from public.action_queue where action like 'discord%' and status = 'Queued';
    insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
    select i.id, d.id, '9000000000000001' || (ascii(lower(right(i.full_name, 1))) - 96),
           'test-instructor-' || lower(right(i.full_name, 1))
      from public.instructor i cross join public.domain d
     where i.is_test and d.name = 'Backend' and i.full_name <> 'Test Instructor E'
    on conflict do nothing;
  `);

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
    marks: [(p) => p.getByLabel('Your Discord username'), button(/^save$/i)],
  },
  {
    file: 'instructors-list.png',
    path: '/setup/instructors',
    before: discordDemo,
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
      await p.locator('tbody tr').filter({ hasText: 'Confirmed' }).first().click();
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
    file: 'discord-servers.png',
    path: '/settings/connections',
    clip: (p) => p.locator('section', { hasText: 'Discord servers' }).first(),
  },
  {
    file: 'instructor-discord.png',
    path: '/setup/instructors',
    before: discordDemo,
    act: async (p) => {
      const show = p.getByLabel('Show test instructors');
      if (!(await show.isChecked())) await show.check();
      await p.locator('tbody tr').filter({ hasText: 'Test Instructor A' }).first().click();
      await p.waitForTimeout(800);
      await p
        .getByRole('dialog')
        .getByText('Their channel in each domain')
        .first()
        .scrollIntoViewIfNeeded();
      await p.waitForTimeout(300);
    },
    marks: [
      (p) => p.getByRole('dialog').getByLabel('Discord username'),
      (p) => p.getByRole('dialog').getByText('Discord found').first(),
      (p) =>
        p
          .getByRole('dialog')
          .getByRole('combobox', { name: /Channel of Test Instructor A in Backend/ }),
    ],
  },
  {
    file: 'classes-regions.png',
    path: '/classes',
    marks: [
      (p) => p.getByRole('combobox', { name: 'Region' }),
      (p) => p.getByRole('combobox', { name: 'Status' }),
      (p) => p.locator('tbody tr').first().locator('td').nth(1),
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

/**
 * The test data names its made up colleagues "Sandbox ..." (older tests use those names). Pictures show the app as
 * people use it, so they are renamed in the test copy first (decision 313).
 */
async function plainNames() {
  const c = new pg.Client({ connectionString: DB });
  await c.connect();
  try {
    // Not a change anyone made, so it is not added to Activity history.
    await c.query(`select set_config('app.suppress_setup_log', 'on', false)`);
    await c.query(
      `update public.team_member set name = replace(name, 'Sandbox ', 'Example '), version = version
        where name like 'Sandbox %'`,
    );
    await c
      .query(
        `update public.history_event set actor_label = 'Test data' where actor_label = 'Sandbox data'`,
      )
      .catch(() => {});
  } finally {
    await c.end();
  }
}

async function main() {
  await plainNames();
  const only = process.argv.slice(2);
  const pics = only.length ? PICS.filter((p) => only.some((o) => p.file.startsWith(o))) : PICS;
  const { api, secret, publishable } = localKeys();
  mkdirSync(OUT, { recursive: true });
  // An app server for the test stack, unless one is already running on the test port.
  const up = await fetch(APP).then(
    () => true,
    () => false,
  );
  const vite = up
    ? undefined
    : spawn(
        process.execPath,
        [
          join(ROOT, 'node_modules', 'vite', 'bin', 'vite.js'),
          join(ROOT, 'app'),
          '--config',
          join(ROOT, 'app', 'vite.config.ts'),
          '--port',
          new URL(APP).port,
          '--strictPort',
        ],
        {
          stdio: 'ignore',
          env: {
            ...process.env,
            VITE_SUPABASE_URL: api,
            VITE_SUPABASE_PUBLISHABLE_KEY: publishable,
            VITE_ALLOWED_EMAIL_DOMAIN: 'example.com',
            VITE_ENABLE_DEV_LOGIN: 'false',
          },
        },
      );
  for (let n = 0; vite && n < 60; n++) {
    if (
      await fetch(APP).then(
        () => true,
        () => false,
      )
    )
      break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  const browser = await chromium
    .launch()
    .catch(() => chromium.launch({ executablePath: chromePath() }));
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    colorScheme: 'light',
  });
  await ctx.addInitScript(() => {
    localStorage.setItem('ik-theme', 'light');
    // The pictures show the app as people use it: no Development label of the local copy (decision 313).
    document.addEventListener('DOMContentLoaded', () => {
      const st = document.createElement('style');
      st.textContent = '[data-environment-label]{display:none!important}';
      document.head.appendChild(st);
    });
  });
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
  vite?.kill();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
