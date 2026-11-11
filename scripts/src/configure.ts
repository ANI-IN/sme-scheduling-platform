// Writes the environment settings that live in the database, from environment variables.
// Run once per environment after the migrations (Sandbox and Production each have their own).
//
//   ALLOWED_EMAIL_DOMAIN=yourcompany.com APP_ENVIRONMENT=Production \
//   DATABASE_URL=postgresql://... npm run configure -w scripts
import pg from 'pg';

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const environment = process.env.APP_ENVIRONMENT;
if (!environment || !['Development', 'Sandbox', 'Production'].includes(environment)) {
  console.error('Set APP_ENVIRONMENT to Development, Sandbox or Production.');
  process.exit(1);
}
if (environment !== 'Development' && !process.env.DATABASE_URL) {
  console.error(`Set DATABASE_URL to the ${environment} Supabase database before configuring it.`);
  process.exit(1);
}
// Development switches off the Google and Sandbox checks, so it is only for a database on this computer.
const host = new URL(url.replace(/^postgres(ql)?:/, 'http:')).hostname;
if (environment === 'Development' && !['localhost', '127.0.0.1', '::1'].includes(host)) {
  console.error(
    `Development is only for a database on this computer, and ${host} is not. Use Sandbox or Production.`,
  );
  process.exit(1);
}
const link = (name: string) => {
  const v = process.env[name]?.trim();
  if (!v) return null;
  if (
    !/^https:\/\/[^/\s]+/.test(v) &&
    !(environment === 'Development' && /^http:\/\/(localhost|127\.0\.0\.1)/.test(v))
  ) {
    console.error(`${name} must start with https://.`);
    process.exit(1);
  }
  return v;
};
const responseBase = link('RESPONSE_BASE_URL');
const appBase = link('APP_BASE_URL');
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
  await c.query('select public.configure_environment($1, $2, $3, $4, $5, $6)', [
    environment,
    domain,
    servers,
    emailDomains,
    responseBase,
    appBase,
  ]);
  console.log(
    `Environment: ${environment}. Company Google accounts allowed: @${domain.toLowerCase()}.`,
  );
} finally {
  await c.end();
}
