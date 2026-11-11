// A separate local Supabase stack for the automated tests, so they never touch the app database
// (decision 250). It has its own containers, its own data and its own ports (5552x instead of 5542x),
// is built from the same migrations, and is removed again when the tests are done.
//
//   npm run test-stack -w scripts -- up      start it if needed and empty it (migrations + seed)
//   npm run test-stack -w scripts -- reset   empty it again
//   npm run test-stack -w scripts -- down    stop it and delete its data
//   npm run test-stack -w scripts -- status  print its address and keys as JSON
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '..', '..');
export const TEST_WORKDIR = join(ROOT, '.test-stack');
export const TEST_DB_URL =
  process.env.TEST_DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55522/postgres';
export const TEST_API_URL = 'http://127.0.0.1:55521';
export const TEST_APP_PORT = 5174;
export const TEST_APP_URL = `http://localhost:${TEST_APP_PORT}`;
const CLI = join(ROOT, 'node_modules', 'supabase', 'dist', 'supabase.js');
// Services the tests do not use. Leaving them out keeps the second stack small.
const EXCLUDE = 'studio,postgres-meta,imgproxy,storage-api,edge-runtime,logflare,vector,supavisor';

const cli = (args: string[], quiet = false) =>
  spawnSync(process.execPath, [CLI, ...args, '--workdir', TEST_WORKDIR], {
    cwd: ROOT,
    stdio: quiet ? 'pipe' : 'inherit',
    encoding: 'utf8',
  });

/** Copy the project's Supabase folder with the test name, ports and app address. */
function writeWorkdir() {
  const dir = join(TEST_WORKDIR, 'supabase');
  rmSync(join(dir, 'migrations'), { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const src = join(ROOT, 'supabase');
  const config = readFileSync(join(src, 'config.toml'), 'utf8')
    .replace(/^project_id = ".*"$/m, 'project_id = "sme-scheduling-test"')
    .replace(/\b554(\d\d)\b/g, '555$1')
    .replace(/(localhost|127\.0\.0\.1):5173/g, `$1:${TEST_APP_PORT}`);
  writeFileSync(join(dir, 'config.toml'), config);
  cpSync(join(src, 'migrations'), join(dir, 'migrations'), { recursive: true });
  for (const f of ['seed.sql', 'seed.local.sql']) cpSync(join(src, f), join(dir, f));
}

export function isRunning() {
  return cli(['status'], true).status === 0;
}

export function up() {
  writeWorkdir();
  if (!isRunning()) {
    console.log('Starting the test stack (its own containers, ports 5552x)...');
    if (cli(['start', '-x', EXCLUDE]).status !== 0)
      throw new Error('The test stack did not start.');
  }
  reset();
}

export function reset() {
  writeWorkdir();
  console.log('Emptying the test stack (migrations and seed)...');
  if (cli(['db', 'reset']).status !== 0) throw new Error('The test stack could not be reset.');
}

export function down() {
  if (existsSync(TEST_WORKDIR)) {
    console.log('Stopping the test stack and deleting its data...');
    cli(['stop', '--no-backup']);
    rmSync(TEST_WORKDIR, { recursive: true, force: true });
  }
}

/** Address and keys of the test stack, from `supabase status`. */
export function keys() {
  const out = execFileSync(
    process.execPath,
    [CLI, 'status', '-o', 'json', '--workdir', TEST_WORKDIR],
    {
      cwd: ROOT,
      encoding: 'utf8',
    },
  );
  const j = JSON.parse(out.slice(out.indexOf('{'))) as Record<string, string>;
  return {
    api: j.API_URL!,
    publishable: j.PUBLISHABLE_KEY ?? j.ANON_KEY!,
    secret: j.SECRET_KEY ?? j.SERVICE_ROLE_KEY!,
  };
}

if (process.argv[1]?.endsWith('test-stack.ts')) {
  const cmd = process.argv[2];
  if (cmd === 'up') up();
  else if (cmd === 'reset') reset();
  else if (cmd === 'down') down();
  else if (cmd === 'status') console.log(JSON.stringify(keys()));
  else {
    console.log('Use: up | reset | down | status');
    process.exitCode = 1;
  }
}
