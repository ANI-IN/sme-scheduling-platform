// The setup command that makes the first admin.
//
//   npm run admins:local -w scripts -- add <email>      the local database
//   npm run admins -w scripts -- list                   the database in .env.production
//   npm run admins -w scripts -- add <email>       make a signed in team member an admin
//   npm run admins -w scripts -- remove <email>    remove admin rights (never the last admin)
//
// After the first admin, admins make each other admins on Settings, Admin. This command calls public.set_admin
// as the automation, so the same rules apply (only someone who has signed in, at least one admin) and each
// change is logged in Activity history as "Setup command". Never prints a connection string.
import pg from 'pg';

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const [cmd = 'list', email] = process.argv.slice(2);
if (!['list', 'add', 'remove'].includes(cmd) || (cmd !== 'list' && !email)) {
  console.error('Use: list, add <email> or remove <email>.');
  process.exit(1);
}

const c = new pg.Client({ connectionString: url });
await c.connect();
try {
  const target = (
    await c.query<{ e: string }>(`select environment e from public.app_config where id = 1`)
  ).rows[0]!.e;
  console.log(`Database: ${new URL(url).hostname} (${target})`);
  if (cmd !== 'list') {
    const t = (
      await c.query<{ id: string; name: string }>(
        `select id, name from public.team_member where lower(email) = lower($1)`,
        [email],
      )
    ).rows[0];
    if (!t) throw new Error(`No team member has the email ${email}. Ask them to sign in first.`);
    await c.query('begin');
    await c.query(
      `select set_config('app.actor_kind', 'System', true), set_config('app.actor_label', 'Setup command', true)`,
    );
    const r = await c.query<{ r: { changed: boolean } }>(`select public.set_admin($1, $2) r`, [
      t.id,
      cmd === 'add',
    ]);
    await c.query('commit');
    console.log(
      r.rows[0]!.r.changed
        ? `${t.name} ${cmd === 'add' ? 'is now an admin' : 'is no longer an admin'}.`
        : `Nothing to change: ${t.name} ${cmd === 'add' ? 'is already an admin' : 'is not an admin'}.`,
    );
  }
  const list = await c.query<{ name: string; email: string }>(
    `select name, email from public.team_member where is_admin and access_removed_at is null order by name`,
  );
  console.log(
    list.rows.length
      ? `Admins: ${list.rows.map((a) => `${a.name} (${a.email})`).join(', ')}`
      : 'There is no admin yet. Add one with: npm run admins -w scripts -- add <email>',
  );
} catch (e) {
  await c.query('rollback').catch(() => {});
  console.error((e as Error).message);
  process.exitCode = 1;
} finally {
  await c.end();
}
