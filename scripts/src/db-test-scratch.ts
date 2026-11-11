// Runs database test files on a throwaway database built from the migrations, so the app database
// is never touched (useful while the end to end tests are using it).
//
//   npm run db:test:scratch -w scripts -- 170_r2_discord_test.sql [more files]
//   npm run db:test:scratch -w scripts             (every file)
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createScratchDb } from './scratch-db.ts';

const serverUrl =
  process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const container = process.env.DB_CONTAINER ?? 'supabase_db_sme-scheduling';
const TESTS = join(import.meta.dirname, '..', '..', 'supabase', 'tests');

const wanted = process.argv.slice(2);
const files = readdirSync(join(TESTS, 'database'))
  .filter(
    (f) =>
      f.endsWith('.sql') && (wanted.length === 0 || wanted.some((w) => f === w || f.startsWith(w))),
  )
  .sort();
if (files.length === 0) {
  console.error(`No test files match: ${wanted.join(', ')}`);
  process.exit(1);
}

const run = (args: string[]) => spawnSync('docker', args, { encoding: 'utf8' });
const scratch = await createScratchDb(serverUrl);
const name = new URL(scratch.url).pathname.slice(1);
let failed = 0;
try {
  run(['exec', container, 'rm', '-rf', '/tmp/sme-tests']);
  const cp = run(['cp', TESTS, `${container}:/tmp/sme-tests`]);
  if (cp.status !== 0) throw new Error(`Could not copy the tests into ${container}: ${cp.stderr}`);
  for (const f of files) {
    const r = run([
      'exec',
      container,
      'psql',
      '-U',
      'postgres',
      '-d',
      name,
      '-q',
      '-v',
      'ON_ERROR_STOP=1',
      '-f',
      `/tmp/sme-tests/database/${f}`,
    ]);
    const out = `${r.stdout}${r.stderr}`;
    const bad = r.status !== 0 || /^\s*not ok/m.test(out) || /Looks like you/m.test(out);
    if (bad) failed++;
    console.log(`${bad ? 'FAIL' : 'ok  '} ${f}`);
    if (bad)
      console.log(
        out
          .split('\n')
          .filter((l) => /not ok|^\s*#|ERROR|psql:/.test(l))
          .join('\n'),
      );
  }
} finally {
  await scratch.drop();
}
console.log(failed ? `${failed} file(s) failed.` : 'All files passed.');
process.exitCode = failed ? 1 : 0;
