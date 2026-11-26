// The database clock on the live database (Release 3, M1, decision 281).
//
//   npm run clock -w scripts -- status
//   npm run clock -w scripts -- on https://<your n8n>/webhook/<WF4 poke path>
//   npm run clock -w scripts -- off
//
// "status" only reads: whether the clock is on, the two scheduled jobs, whether the poke key is in Vault (yes or
// no, never its value), the last call to n8n and n8n runs counted this month. "on" and "off" call
// public.configure_clock, which is logged in Activity history. Switching on also tries one call to WF4 and shows
// the result. Refuses anything but the live project.
import pg from 'pg';

/** Your hosted Supabase project ID: the only database this script accepts. */
const LIVE_REF = process.env.SUPABASE_PROJECT_REF ?? '';
const url = process.env.DATABASE_URL ?? '';
if (!LIVE_REF || !url.includes(LIVE_REF)) {
  console.error(
    LIVE_REF
      ? `Refusing: DATABASE_URL is not the project ${LIVE_REF} (SUPABASE_PROJECT_REF).`
      : 'Refusing: set SUPABASE_PROJECT_REF to your Supabase project ID.',
  );
  process.exit(1);
}
const [cmd = 'status', pokeUrl] = process.argv.slice(2);
if (!['status', 'on', 'off'].includes(cmd)) {
  console.error('Use: status, on <WF4 poke address>, or off.');
  process.exit(1);
}

const c = new pg.Client({ connectionString: url });
await c.connect();
try {
  if (cmd !== 'status') {
    const r = await c.query<{ r: unknown }>(`select public.configure_clock($1, $2) r`, [
      cmd === 'on',
      pokeUrl ?? null,
    ]);
    console.log(`Clock switched ${cmd}:`, JSON.stringify(r.rows[0]!.r));
  }
  const s = await c.query(`
    select c.clock_enabled, c.n8n_poke_url is not null as poke_address_set,
           exists (select 1 from vault.secrets where name = 'n8n_poke_key') as poke_key_in_vault,
           st.last_poke_at, st.last_reason, st.last_result, st.last_reply_read_at,
           public.n8n_runs_this_month() as n8n_runs_this_month
      from public.app_config c, public.clock_state st where c.id = 1 and st.id = 1`);
  console.log(s.rows[0]);
  const jobs = await c
    .query(
      `select jobname, schedule, active from cron.job where jobname like 'sme-%' order by jobname`,
    )
    .catch(() => ({ rows: [{ note: 'pg_cron is not installed' }] }));
  console.log('Scheduled jobs:', jobs.rows);
  const runs = await c.query(
    `select workflow, runs, last_at from public.n8n_usage
      where month = date_trunc('month', now() at time zone 'UTC')::date order by workflow`,
  );
  console.log('n8n runs this month by workflow:', runs.rows);
} finally {
  await c.end();
}
