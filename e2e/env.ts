// Shared settings for the end to end tests: where the app and the local database are.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

export const ROOT = join(import.meta.dirname, '..');
// The tests run in their own local stack (scripts/src/test-stack.ts): app on 5174, database on 55522.
export const APP = process.env.E2E_APP_URL ?? 'http://localhost:5174';
export const DB_URL =
  process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55522/postgres';
/** The account the tests sign in with. The demo data gives it the Sandbox operations role. */
export const EMAIL = process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com';
export const AUTH_FILE = join(import.meta.dirname, 'results', '.auth.json');

let keys: { api: string; publishable: string; secret: string } | undefined;
/** The test stack's address and keys, read from `supabase status`. */
export function localKeys() {
  if (keys) return keys;
  // Test workers inherit the keys from the runner, so `supabase status` runs once per run.
  if (process.env.E2E_SUPABASE_KEYS) return (keys = JSON.parse(process.env.E2E_SUPABASE_KEYS));
  const out = execFileSync(
    'node',
    [
      join(ROOT, 'node_modules', 'supabase', 'dist', 'supabase.js'),
      'status',
      '-o',
      'json',
      '--workdir',
      join(ROOT, '.test-stack'),
    ],
    { cwd: ROOT, encoding: 'utf8' },
  );
  const j = JSON.parse(out.slice(out.indexOf('{'))) as Record<string, string>;
  keys = {
    api: j.API_URL!,
    publishable: j.PUBLISHABLE_KEY ?? j.ANON_KEY!,
    secret: j.SECRET_KEY ?? j.SERVICE_ROLE_KEY!,
  };
  process.env.E2E_SUPABASE_KEYS = JSON.stringify(keys);
  return keys;
}

/** On a developer machine, use any Chromium Playwright installed; in CI Playwright finds its own. */
export function chromePath(): string | undefined {
  if (process.env.CI) return undefined;
  const base = join(
    process.env.LOCALAPPDATA ?? join(process.env.HOME ?? '', '.cache'),
    'ms-playwright',
  );
  if (!existsSync(base)) return undefined;
  for (const d of readdirSync(base)
    .filter((x) => /^chromium-\d+$/.test(x))
    .sort()
    .reverse()) {
    for (const exe of [
      'chrome-win64/chrome.exe',
      'chrome-win/chrome.exe',
      'chrome-linux64/chrome',
    ]) {
      if (existsSync(join(base, d, exe))) return join(base, d, exe);
    }
  }
  return undefined;
}

/** A one time sign in link for a company account (the local database runs as Development). */
export async function signInLink(email: string): Promise<string> {
  const { api, secret } = localKeys();
  const res = await fetch(`${api}/auth/v1/admin/generate_link`, {
    method: 'POST',
    headers: {
      apikey: secret,
      Authorization: `Bearer ${secret}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ type: 'magiclink', email, redirect_to: APP }),
  });
  const j = (await res.json()) as { action_link?: string; properties?: { action_link?: string } };
  const link = j.action_link ?? j.properties?.action_link;
  if (!link) throw new Error(`Could not create a sign in link: ${JSON.stringify(j)}`);
  return link;
}
