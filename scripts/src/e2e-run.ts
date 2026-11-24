// Runs the end to end tests in their own local stack (decision 250), never on the app database.
//
//   npm run e2e                                   every project
//   npm run e2e -- --project=scenarios            Playwright options after --
//   npm run e2e -- --keep --project=scenarios     keep the test stack running afterwards (faster reruns)
//   npm run e2e:scale                             time limits per page with 60 cohorts and 160 instructors
//   npm run e2e -- --pages                        only the warm up and the page tests
//
// It starts the test stack (scripts/src/test-stack.ts, ports 5552x) or empties it if it is running, loads
// the test data, runs Playwright against an app server on port 5174 that talks to the test stack, and
// stops the test stack and deletes its data at the end (unless --keep).
import { spawn, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import pg from 'pg';
import { down, keys, TEST_APP_URL, TEST_DB_URL, up } from './test-stack.ts';

const ROOT = join(import.meta.dirname, '..', '..');
const all = process.argv.slice(2);
const keep = all.includes('--keep') || process.env.E2E_KEEP_STACK === '1';
const scale = all.includes('--scale');
// --pages: only the warm up and the page tests (the first phase of a full run).
const pagesOnly = all.includes('--pages');
const args = all.filter((a) => a !== '--keep' && a !== '--scale' && a !== '--pages');

up();
const k = keys();
const env = {
  ...process.env,
  E2E_WRAPPED: '1',
  DATABASE_URL: TEST_DB_URL,
  E2E_APP_URL: TEST_APP_URL,
  E2E_SUPABASE_KEYS: JSON.stringify(k),
};
const run = (cmd: string, a: string[], cwd = ROOT, extra: Record<string, string> = {}) =>
  spawnSync(cmd, a, { cwd, stdio: 'inherit', shell: false, env: { ...env, ...extra } }).status ?? 1;
const playwright = (a: string[], phase = '') =>
  run(
    process.execPath,
    [join(ROOT, 'node_modules', '@playwright', 'test', 'cli.js'), 'test', ...a],
    join(ROOT, 'e2e'),
    phase ? { E2E_PHASE: phase } : {},
  );

let status = run(
  process.execPath,
  [
    join(ROOT, 'node_modules', 'tsx', 'dist', 'cli.mjs'),
    'src/demo-data.ts',
    'load',
    ...(scale ? ['--scale'] : []),
  ],
  join(ROOT, 'scripts'),
);
/**
 * Wait until the freshly reset test database is quiet: no other session busy and no lock waits for two seconds in a
 * row (at most a minute). Right after a reset the stack's own services run their setup, and on 24 November the very
 * first page test waited behind them until its 8 second limit.
 */
async function settle() {
  const c = new pg.Client({ connectionString: TEST_DB_URL });
  await c.connect();
  let quiet = 0;
  for (let i = 0; i < 120 && quiet < 4; i++) {
    const r = await c.query<{ busy: number; waiting: number }>(
      `select count(*) filter (where state = 'active' and pid <> pg_backend_pid() and backend_type = 'client backend'
                                 and query not ilike '%pg_sleep%' and query not ilike '%LISTEN%'
                                 and query not ilike 'START_REPLICATION%')::int busy,
              count(*) filter (where wait_event_type = 'Lock')::int waiting
         from pg_stat_activity`,
    );
    quiet = r.rows[0]!.busy === 0 && r.rows[0]!.waiting === 0 ? quiet + 1 : 0;
    await new Promise((res) => setTimeout(res, 500));
  }
  await c.end();
}

/**
 * The app server for every phase (Playwright reuses it): started once here, so the code it compiles on the first
 * visit of each page stays compiled for the whole run.
 */
async function startApp() {
  const vite = spawn(
    process.execPath,
    [
      join(ROOT, 'node_modules', 'vite', 'bin', 'vite.js'),
      join(ROOT, 'app'),
      '--config',
      join(ROOT, 'app', 'vite.config.ts'),
      '--port',
      '5174',
      '--strictPort',
    ],
    {
      cwd: join(ROOT, 'e2e'),
      stdio: 'ignore',
      env: {
        ...env,
        VITE_SUPABASE_URL: k.api,
        VITE_SUPABASE_PUBLISHABLE_KEY: k.publishable,
        VITE_ALLOWED_EMAIL_DOMAIN: 'example.com',
        VITE_ENABLE_DEV_LOGIN: 'false',
      },
    },
  );
  for (let i = 0; i < 120; i++) {
    if (
      await fetch(TEST_APP_URL).then(
        (r) => r.ok,
        () => false,
      )
    )
      break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return vite;
}

let app: ReturnType<typeof spawn> | undefined;
if (status === 0) {
  await settle();
  app = await startApp();
  if (args.length > 0) {
    status = playwright(args);
  } else {
    // Everything: the page tests only read data, so they run four at a time; the click through
    // and the scenarios change data, so they run one at a time afterwards.
    const pages = ['desktop', 'laptop', 'tablet', 'mobile'].flatMap((w) => [
      `${w}-light`,
      `${w}-dark`,
    ]);
    // Warm up first (not counted): the development server compiles each page's code on its first visit, and four
    // workers doing that at once starved the machine for the first tests (24 November: plain reads took 5 to 16 s).
    playwright(
      ['--project=desktop-light', '--workers=1', '--reporter=dot', '-g', 'page /'],
      'warmup',
    );
    status = playwright([...pages.map((p) => `--project=${p}`), '--workers=4'], 'pages');
    const rest = pagesOnly
      ? 0
      : playwright(
          ['--project=crawl-desktop', '--project=crawl-mobile', '--project=scenarios'],
          'flows',
        );
    status = status || rest;
  }
}
app?.kill();
if (!keep) down();
process.exit(status);
