// Backs up the live database and proves the backup is complete (docs/DEPLOYMENT.md).
//
//   npm run backup -w scripts -- --label before-m0
//
// Only one backup runs at a time (a lock file in the backup folder, and no pg_dump already working in the
// container); --help and unknown options start nothing.
//
// 1. Refuses anything but your hosted project (SUPABASE_PROJECT_REF).
// 2. Dumps the whole database (every schema, structure and data) with pg_dump 17 from the local Supabase container
//    to Backups/sme-scheduling in your home folder (or BACKUP_DIR), outside the repository, with the date in its name.
// 3. Restores the file into a throwaway database on the local Postgres and compares the row count of every table
//    with the live database, prints the comparison and saves it next to the backup (.counts.txt).
// 4. Drops the throwaway database. The live database is only read.
//
// The connection string is passed to Docker through the environment and is never printed.
import { spawnSync } from 'node:child_process';
import {
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { busyReason, parseArgs, USAGE, type Lock } from './backup-lib.ts';

/** Your hosted Supabase project ID: the only database this script accepts. */
const LIVE_REF = process.env.SUPABASE_PROJECT_REF ?? '';
const CONTAINER = 'supabase_db_sme-scheduling';
const LOCAL_URL = 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const DIR = process.env.BACKUP_DIR ?? join(homedir(), 'Backups', 'sme-scheduling');

const args = parseArgs(process.argv.slice(2));
if ('help' in args) {
  console.log(USAGE);
  process.exit(0);
}
if ('error' in args) {
  console.error(`${args.error}\n\n${USAGE}`);
  process.exit(1);
}
const { label } = args;
const live = process.env.DATABASE_URL ?? '';
if (!LIVE_REF || !live.includes(LIVE_REF)) {
  console.error(
    LIVE_REF
      ? `Refusing: DATABASE_URL is not the project ${LIVE_REF} (SUPABASE_PROJECT_REF).`
      : 'Refusing: set SUPABASE_PROJECT_REF to your Supabase project ID.',
  );
  process.exit(1);
}

// One backup at a time.
mkdirSync(DIR, { recursive: true });
const LOCK = join(DIR, '.backup.lock');
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'EPERM';
  }
};
const readLock = (): Lock | null => {
  try {
    return JSON.parse(readFileSync(LOCK, 'utf8')) as Lock;
  } catch {
    return null;
  }
};
const dumpsInContainer = () => {
  const r = spawnSync(
    'docker',
    ['exec', CONTAINER, 'sh', '-c', "ps -eo pid,args | grep '[p]g_dump' || true"],
    { encoding: 'utf8' },
  );
  return r.status === 0 ? r.stdout.split('\n').filter(Boolean) : [];
};
const refuse = (why: string): never => {
  console.error(why);
  process.exit(1);
};
const held = busyReason(readLock(), alive, []);
if (held) refuse(held);
const other = busyReason(null, alive, dumpsInContainer());
if (other) refuse(other);
rmSync(LOCK, { force: true }); // left by a run that is gone
try {
  writeFileSync(LOCK, JSON.stringify({ pid: process.pid, started: new Date().toISOString() }), {
    flag: 'wx',
  });
} catch {
  refuse('A backup is already running (another one started this moment). Wait for it to finish.');
}
process.on('exit', () => {
  if (readLock()?.pid === process.pid) rmSync(LOCK, { force: true });
});

const now = new Date();
const pad = (n: number) => String(n).padStart(2, '0');
const stamp = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}`;
const file = join(DIR, `sme-scheduling-${stamp}-${label}.dump`);

/**
 * pg_cron lives only in the main `postgres` database, so its schema cannot be restored into the throwaway database.
 * Its tables are counted in the backup file itself: the rows of each table's COPY section.
 */
const CRON_TABLES = ['cron.job', 'cron.job_run_details'];
/** The run log grows every minute while the clock's jobs are scheduled, so live may have a few more rows. */
const GROWING_LOGS = new Set(['cron.job_run_details']);
function countInFile(dump: string, table: string): number | undefined {
  const [schema, name] = table.split('.') as [string, string];
  const r = spawnSync(
    'docker',
    ['exec', '-i', CONTAINER, 'pg_restore', '--data-only', '-n', schema, '-t', name, '-f', '-'],
    { input: readFileSync(dump), maxBuffer: 1 << 28 },
  );
  if (r.status !== 0) return undefined;
  const lines = String(r.stdout).split('\n');
  const start = lines.findIndex((l) => l.startsWith(`COPY ${schema}.${name} `));
  if (start < 0) return undefined;
  const end = lines.indexOf('\\.', start + 1);
  return end < 0 ? undefined : end - start - 1;
}

/** Row counts of every table outside the system schemas. */
async function counts(url: string): Promise<Map<string, number>> {
  const c = new pg.Client({ connectionString: url });
  await c.connect();
  try {
    await c.query('set default_transaction_read_only = on');
    const t = await c.query<{ q: string }>(
      `select format('%I.%I', n.nspname, c.relname) q from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r', 'p') and n.nspname not in ('pg_catalog', 'information_schema')
          and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%' and not c.relispartition
        order by 1`,
    );
    const out = new Map<string, number>();
    for (const { q } of t.rows) {
      const r = await c.query<{ n: string }>(`select count(*) n from ${q}`).catch(() => null);
      out.set(q, r ? Number(r.rows[0]!.n) : -1);
    }
    return out;
  } finally {
    await c.end();
  }
}

// 2. The dump, taken while nothing else is read from the live database.
console.log(`Backing up the live database to ${file} ...`);
const fd = openSync(file, 'w');
const dump = spawnSync(
  'docker',
  ['exec', '-e', 'DBURL', CONTAINER, 'sh', '-c', 'pg_dump "$DBURL" --format=custom --no-password'],
  { stdio: ['ignore', fd, 'pipe'], env: { ...process.env, DBURL: live }, maxBuffer: 1 << 26 },
);
closeSync(fd);
if (dump.status !== 0) {
  console.error(`pg_dump failed: ${String(dump.stderr).replaceAll(live, '[the live database]')}`);
  process.exit(1);
}
const liveCounts = await counts(live);
const size = statSync(file).size;
console.log(
  `Saved ${(size / 1024 / 1024).toFixed(1)} MB. Restoring it into a throwaway local database ...`,
);

// 3. Restore into a throwaway database and compare.
const name = `sme_backup_check_${process.pid}`;
const admin = new pg.Client({ connectionString: LOCAL_URL });
await admin.connect();
await admin.query(`drop database if exists ${name} with (force)`);
await admin.query(`create database ${name}`);
let report = '';
let differ = 0;
try {
  const restore = spawnSync(
    'docker',
    [
      'exec',
      '-i',
      CONTAINER,
      'pg_restore',
      '--no-owner',
      '--no-privileges',
      '-U',
      'postgres',
      '-d',
      name,
    ],
    { input: readFileSync(file), maxBuffer: 1 << 26 },
  );
  // Supabase's own objects (roles, event triggers, extensions owned by Supabase) may report errors locally; what
  // matters is that every table and every row came back, which the comparison below checks.
  const restoreErrors = (String(restore.stderr).match(/error:/gi) ?? []).length;
  const backupCounts = await counts(LOCAL_URL.replace(/\/postgres$/, `/${name}`));
  for (const t of CRON_TABLES) {
    if (liveCounts.has(t) && !backupCounts.has(t)) {
      const n = countInFile(file, t);
      if (n !== undefined) backupCounts.set(t, n);
    }
  }
  const names = [...new Set([...liveCounts.keys(), ...backupCounts.keys()])].sort();
  const rows = names.map((t) => {
    const a = liveCounts.get(t);
    const b = backupCounts.get(t);
    // A run log written while the backup ran: the backup has the rows up to the dump, live a few more.
    const log = GROWING_LOGS.has(t) && a !== undefined && b !== undefined && b <= a && a - b <= 60;
    const same = a === b || log;
    if (!same) differ += 1;
    const mark = a === b ? 'same ' : log ? 'log  ' : 'DIFF ';
    const where = CRON_TABLES.includes(t) ? ' (counted in the file)' : '';
    return `${mark} ${t.padEnd(52)} live ${String(a ?? 'missing').padStart(7)}  backup ${String(b ?? 'missing').padStart(7)}${where}`;
  });
  const liveRows = [...liveCounts.values()].reduce((s, n) => s + Math.max(n, 0), 0);
  report = [
    `Backup: ${file} (${(size / 1024 / 1024).toFixed(1)} MB)`,
    `Taken: ${now.toISOString()}`,
    `Tables: ${names.length}, rows on the live database: ${liveRows}`,
    `Tables that differ: ${differ}`,
    `Restore messages reported as errors (Supabase's own objects): ${restoreErrors}`,
    '',
    ...rows,
  ].join('\n');
} finally {
  await admin.query(`drop database if exists ${name} with (force)`);
  await admin.end();
}
writeFileSync(file.replace(/\.dump$/, '.counts.txt'), report + '\n');
console.log(report);
console.log(
  differ === 0
    ? '\nVerified: every table has the same number of rows in the backup as on the live database.'
    : `\n${differ} table(s) differ. A table written to while the backup ran (for example by n8n) can differ by a few rows; anything else means the backup is not complete.`,
);
process.exitCode = differ === 0 ? 0 : 2;
