// Runs the end to end tests in their own local stack (decision 250), never on the app database.
//
//   npm run e2e                                   every project
//   npm run e2e -- --project=scenarios            Playwright options after --
//   npm run e2e -- --keep --project=scenarios     keep the test stack running afterwards (faster reruns)
//
// It starts the test stack (scripts/src/test-stack.ts, ports 5552x) or empties it if it is running, loads
// the test data, runs Playwright against an app server on port 5174 that talks to the test stack, and
// stops the test stack and deletes its data at the end (unless --keep).
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { down, keys, TEST_APP_URL, TEST_DB_URL, up } from './test-stack.ts';

const ROOT = join(import.meta.dirname, '..', '..');
const all = process.argv.slice(2);
const keep = all.includes('--keep') || process.env.E2E_KEEP_STACK === '1';
const args = all.filter((a) => a !== '--keep');

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
  [join(ROOT, 'node_modules', 'tsx', 'dist', 'cli.mjs'), 'src/demo-data.ts', 'load'],
  join(ROOT, 'scripts'),
);
if (status === 0) {
  if (args.length > 0) {
    status = playwright(args);
  } else {
    // Everything: the page tests only read data, so they run four at a time; the click through
    // and the scenarios change data, so they run one at a time afterwards.
    const pages = ['desktop', 'laptop', 'tablet', 'mobile'].flatMap((w) => [
      `${w}-light`,
      `${w}-dark`,
    ]);
    status = playwright([...pages.map((p) => `--project=${p}`), '--workers=4'], 'pages');
    const rest = playwright(
      ['--project=crawl-desktop', '--project=crawl-mobile', '--project=scenarios'],
      'flows',
    );
    status = status || rest;
  }
}
if (!keep) down();
process.exit(status);
