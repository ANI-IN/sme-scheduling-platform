// The backup script starts only one backup at a time, and asking for help never starts one.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { busyReason, parseArgs } from './backup-lib.ts';

const here = import.meta.dirname;
/** The real script with a made up live address (it must stop before reading it) and an empty backup folder. */
function run(args: string[], dir: string) {
  return spawnSync(process.execPath, ['--import', 'tsx', join(here, 'backup.ts'), ...args], {
    encoding: 'utf8',
    timeout: 60_000,
    cwd: join(here, '..'),
    env: {
      ...process.env,
      DATABASE_URL: 'postgresql://x:x@127.0.0.1:1/abcdefghijklmnopqrst',
      BACKUP_DIR: dir,
    },
  });
}
const folder = () => mkdtempSync(join(tmpdir(), 'sme-backup-test-'));

test('--help prints how to use it and starts nothing', () => {
  const dir = folder();
  for (const flag of ['--help', '-h']) {
    const r = run([flag], dir);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /npm run backup/);
  }
  assert.deepEqual(readdirSync(dir), []);
  rmSync(dir, { recursive: true, force: true });
});

test('an unknown option starts nothing', () => {
  const dir = folder();
  const r = run(['--lable', 'x'], dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /Unknown option/);
  assert.deepEqual(readdirSync(dir), []);
  rmSync(dir, { recursive: true, force: true });
});

test('a second backup is refused while one runs', () => {
  const dir = folder();
  writeFileSync(join(dir, '.backup.lock'), JSON.stringify({ pid: process.pid, started: 'now' }));
  const r = run(['--label', 'second'], dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /already running/);
  assert.deepEqual(readdirSync(dir), ['.backup.lock']);
  rmSync(dir, { recursive: true, force: true });
});

test('what counts as busy: a live lock, or a dump still running in the database container', () => {
  const alive = (pid: number) => pid === 7;
  assert.equal(busyReason(null, alive, []), null);
  assert.equal(
    busyReason({ pid: 8, started: 'x' }, alive, []),
    null,
    'a lock left by a stopped run',
  );
  assert.match(busyReason({ pid: 7, started: 'x' }, alive, [])!, /already running/);
  assert.match(busyReason(null, alive, ['1234 pg_dump postgresql://…'])!, /pg_dump/);
});

test('arguments', () => {
  assert.deepEqual(parseArgs([]), { label: 'manual' });
  assert.deepEqual(parseArgs(['--label', 'before-release-batch-5']), {
    label: 'before-release-batch-5',
  });
  assert.deepEqual(parseArgs(['--help', '--label', 'x']), { help: true });
  assert.ok('error' in parseArgs(['--label']));
  assert.ok('error' in parseArgs(['--label', 'Bad Label']));
});
