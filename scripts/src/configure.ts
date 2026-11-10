// Writes the environment settings that live in the database, from environment variables.
// Run once per environment after the migrations (Sandbox and Production each have their own).
//
//   ALLOWED_EMAIL_DOMAIN=yourcompany.com APP_ENVIRONMENT=Production \
//   DATABASE_URL=postgresql://... npm run configure -w scripts
import pg from 'pg';

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const environment = process.env.APP_ENVIRONMENT ?? 'Development';
if (environment !== 'Development' && !process.env.DATABASE_URL) {
  console.error(`Set DATABASE_URL to the ${environment} Supabase database before configuring it.`);
  process.exit(1);
}
const domain = process.env.ALLOWED_EMAIL_DOMAIN;
if (!domain) {
  console.error('Set ALLOWED_EMAIL_DOMAIN (for example yourcompany.com).');
  process.exit(1);
}
const list = (v: string | undefined) =>
  v === undefined
    ? null
    : v
        .split(',')
        .map((x) => x.trim())
        .filter(Boolean);
const servers = list(process.env.SANDBOX_ALLOWED_DISCORD_SERVERS);
const emailDomains = list(process.env.SANDBOX_ALLOWED_EMAIL_DOMAINS);
if (environment === 'Sandbox' && (!servers?.length || !emailDomains?.length)) {
  console.warn(
    'Warning: SANDBOX_ALLOWED_DISCORD_SERVERS or SANDBOX_ALLOWED_EMAIL_DOMAINS is empty, so this Sandbox cannot send those messages.',
  );
}
const c = new pg.Client({ connectionString: url });
await c.connect();
try {
  await c.query('select public.configure_environment($1, $2, $3, $4)', [
    environment,
    domain,
    servers,
    emailDomains,
  ]);
  console.log(
    `Environment: ${environment}. Company Google accounts allowed: @${domain.toLowerCase()}.`,
  );
} finally {
  await c.end();
}
