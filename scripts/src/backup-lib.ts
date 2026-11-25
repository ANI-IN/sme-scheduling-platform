// The parts of the backup script that decide whether to start one (kept apart so they are tested).
export const USAGE = `Usage: npm run backup -w scripts -- [--label before-release-batch-5]

Backs up the live database to C:\Users\you\Backups\sme-scheduling\ and checks the copy restores.
--label  lower case letters, digits and "-" (default: manual)
--help   show this and do nothing`;

export type Args = { help: true } | { label: string } | { error: string };

export function parseArgs(argv: string[]): Args {
  if (argv.includes('--help') || argv.includes('-h')) return { help: true };
  let label = 'manual';
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] !== '--label') return { error: `Unknown option: ${argv[i]}` };
    const v = argv[++i];
    if (v === undefined) return { error: '--label needs a value.' };
    label = v;
  }
  if (!/^[a-z0-9-]+$/.test(label))
    return { error: 'The label may contain only lower case letters, digits and "-".' };
  return { label };
}

export type Lock = { pid: number; started: string };

/** Why a backup may not start now, or null. `dumps` are the pg_dump processes seen in the database container. */
export function busyReason(
  lock: Lock | null,
  alive: (pid: number) => boolean,
  dumps: string[],
): string | null {
  if (lock && alive(lock.pid))
    return `A backup is already running (process ${lock.pid}, started ${lock.started}). Wait for it to finish.`;
  if (dumps.length)
    return 'A backup is already running: pg_dump is still working in the local database container (a backup stopped part way leaves it behind). Wait for it, or end it there, then start again.';
  return null;
}
