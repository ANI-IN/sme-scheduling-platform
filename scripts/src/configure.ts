// Writes the environment settings that live in the database, from environment variables.
// Run once per environment after the migrations (Sandbox and Production each have their own).
//
//   npm run configure:sandbox -w scripts      (reads .env.sandbox)
//   npm run configure:production -w scripts   (reads .env.production)
//
// The environment comes from `--env Sandbox|Production|Development` (what the two commands above pass),
// or else from APP_ENVIRONMENT. Nothing is set on the command line itself, so it works in every shell.
import pg from 'pg';

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const arg = process.argv.indexOf('--env');
const environment = (arg > -1 ? process.argv[arg + 1] : undefined) ?? process.env.APP_ENVIRONMENT;
if (!environment || !['Development', 'Sandbox', 'Production'].includes(environment)) {
  console.error(
    'Say which environment: --env Development, Sandbox or Production (or set APP_ENVIRONMENT).',
  );
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
