// Shared by the screenshot scripts: find a Chromium, read the local keys, make a sign in link.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '..', '..');

/** Use Playwright's own browser, or any Chromium Playwright has installed on this machine. */
export function chromePath(): string | undefined {
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
      'chrome-linux/chrome',
      'chrome-linux64/chrome',
    ]) {
      if (existsSync(join(base, d, exe))) return join(base, d, exe);
    }
  }
  return undefined;
}

/** Address and keys of the separate test stack (scripts/src/test-stack.ts), never the app database. */
export function localKeys(): { api: string; secret: string; publishable: string } {
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
    {
      cwd: ROOT,
      encoding: 'utf8',
    },
  );
  const j = JSON.parse(out.slice(out.indexOf('{'))) as Record<string, string>;
  return {
    api: j.API_URL!,
    secret: j.SECRET_KEY ?? j.SERVICE_ROLE_KEY!,
    publishable: j.PUBLISHABLE_KEY ?? j.ANON_KEY!,
  };
}

export async function signInLink(
  api: string,
  secret: string,
  email: string,
  app: string,
): Promise<string> {
  const res = await fetch(`${api}/auth/v1/admin/generate_link`, {
    method: 'POST',
    headers: {
      apikey: secret,
      Authorization: `Bearer ${secret}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ type: 'magiclink', email, redirect_to: app }),
  });
  const j = (await res.json()) as { action_link?: string; properties?: { action_link?: string } };
  const link = j.action_link ?? j.properties?.action_link;
  if (!link) throw new Error(`Could not create a sign-in link: ${JSON.stringify(j)}`);
  return link;
}
