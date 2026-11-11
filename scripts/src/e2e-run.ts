// Runs the end to end tests on known data, then puts your local data back.
//
//   npm run e2e                     every project
//   npm run e2e -- --project=scenarios
//
// On a developer machine: saves the local app data, loads the Sandbox starting data plus a few
// confirmed and asked class weeks, runs Playwright, and restores the saved data (even when tests fail).
// In CI (CI=true) there is nothing to keep, so it only loads the data and runs the tests.
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '..', '..');
const ci = !!process.env.CI;
const run = (cmd: string, args: string[], cwd = ROOT, env: Record<string, string> = {}) =>
  spawnSync(cmd, args, {
    cwd,
    stdio: 'inherit',
    shell: false,
    env: { ...process.env, E2E_WRAPPED: '1', ...env },
  }).status ?? 1;
const demo = (step: string) =>
  run(
    process.execPath,
    [join(ROOT, 'node_modules', 'tsx', 'dist', 'cli.mjs'), 'src/demo-data.ts', step],
    join(ROOT, 'scripts'),
  );

if (!ci && demo('snapshot') !== 0) process.exit(1);
const playwright = (args: string[], phase = '') =>
  run(
    process.execPath,
    [join(ROOT, 'node_modules', '@playwright', 'test', 'cli.js'), 'test', ...args],
    join(ROOT, 'e2e'),
    phase ? { E2E_PHASE: phase } : {},
  );
const args = process.argv.slice(2);
let status = demo('load');
if (status === 0) {
  if (args.length > 0) {
    status = playwright(args);
  } else {
    // Everything: the page tests only read data, so they run four at a time; the click through
    // and the scenarios change data, so they run one at a time afterwards.
    const pages = ['desktop-light', 'desktop-dark', 'mobile-light', 'mobile-dark'];
    status = playwright([...pages.map((p) => `--project=${p}`), '--workers=4'], 'pages');
    const rest = playwright(
      ['--project=crawl-desktop', '--project=crawl-mobile', '--project=scenarios'],
      'flows',
    );
    status = status || rest;
  }
}
if (!ci && demo('restore') !== 0) status = status || 1;
process.exit(status);
