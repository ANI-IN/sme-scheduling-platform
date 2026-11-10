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
const run = (cmd: string, args: string[], cwd = ROOT) =>
  spawnSync(cmd, args, {
    cwd,
    stdio: 'inherit',
    shell: false,
    env: { ...process.env, E2E_WRAPPED: '1' },
  }).status ?? 1;
const demo = (step: string) =>
  run(
    process.execPath,
    [join(ROOT, 'node_modules', 'tsx', 'dist', 'cli.mjs'), 'src/demo-data.ts', step],
    join(ROOT, 'scripts'),
  );

if (!ci && demo('snapshot') !== 0) process.exit(1);
let status = demo('load');
if (status === 0) {
  status = run(
    process.execPath,
    [join(ROOT, 'node_modules', '@playwright', 'test', 'cli.js'), 'test', ...process.argv.slice(2)],
    join(ROOT, 'e2e'),
  );
}
if (!ci && demo('restore') !== 0) status = status || 1;
process.exit(status);
