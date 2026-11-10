// Screenshots of every page, drawer and dialog in light and dark themes, desktop and mobile.
//   npm run screenshots -w scripts                 # everything into docs/screenshots/
//   npm run screenshots -w scripts -- home classes # only shots whose name starts with these
// Needs the local stack (npm run db:start) and the app dev server on http://localhost:5173.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { chromium, type Page } from 'playwright';

const ROOT = join(import.meta.dirname, '..', '..');
const OUT = join(ROOT, 'docs', 'screenshots');
const APP = process.env.APP_URL ?? 'http://localhost:5173';
const EMAIL = process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com';

/** Use Playwright's own browser, or any Chromium Playwright has installed on this machine. */
function chromePath(): string | undefined {
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

type Shot = { name: string; path: string; act?: (p: Page) => Promise<void> };

function localKeys(): { api: string; secret: string } {
  const out = execFileSync(
    'node',
    [join(ROOT, 'node_modules', 'supabase', 'dist', 'supabase.js'), 'status', '-o', 'json'],
    {
      cwd: ROOT,
      encoding: 'utf8',
    },
  );
  const j = JSON.parse(out.slice(out.indexOf('{'))) as Record<string, string>;
  return { api: j.API_URL!, secret: j.SECRET_KEY ?? j.SERVICE_ROLE_KEY! };
}

async function signInLink(api: string, secret: string): Promise<string> {
  const res = await fetch(`${api}/auth/v1/admin/generate_link`, {
    method: 'POST',
    headers: {
      apikey: secret,
      Authorization: `Bearer ${secret}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ type: 'magiclink', email: EMAIL, redirect_to: APP }),
  });
  const j = (await res.json()) as { action_link?: string; properties?: { action_link?: string } };
  const link = j.action_link ?? j.properties?.action_link;
  if (!link) throw new Error(`Could not create a sign-in link: ${JSON.stringify(j)}`);
  return link;
}

const click = (text: string | RegExp) => async (p: Page) => {
  await p.getByRole('button', { name: text }).first().click();
  await p.waitForTimeout(700);
};
const clickRow = (selector: string) => async (p: Page) => {
  await p.locator(selector).first().click();
  await p.waitForTimeout(800);
};

export const SHOTS: Shot[] = [
  { name: 'home', path: '/' },
  { name: 'classes', path: '/classes' },
  { name: 'classes-plan-dialog', path: '/classes', act: click(/plan classes/i) },
  { name: 'classes-class-drawer', path: '/classes', act: clickRow('tbody tr') },
  { name: 'requests', path: '/requests' },
  { name: 'requests-choose-who', path: '/requests', act: click(/choose who to ask/i) },
  { name: 'modules', path: '/setup/modules' },
  { name: 'modules-new-flow', path: '/setup/modules/new' },
  { name: 'module-detail', path: '/setup/modules', act: clickRow('tbody tr') },
  { name: 'instructors', path: '/setup/instructors' },
  { name: 'instructors-add-drawer', path: '/setup/instructors', act: click(/add instructor/i) },
  { name: 'instructors-edit-drawer', path: '/setup/instructors', act: clickRow('tbody tr') },
  { name: 'team', path: '/setup/team' },
  { name: 'domains', path: '/setup/domains' },
  { name: 'settings-automation', path: '/settings/automation' },
  { name: 'settings-testing', path: '/settings/testing' },
  { name: 'settings-connections', path: '/settings/connections' },
  { name: 'activity', path: '/activity' },
];

async function main() {
  const only = process.argv.slice(2);
  const shots = only.length ? SHOTS.filter((s) => only.some((o) => s.name.startsWith(o))) : SHOTS;
  const { api, secret } = localKeys();
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium
    .launch()
    .catch(() => chromium.launch({ executablePath: chromePath() }));
  for (const theme of ['light', 'dark'] as const) {
    for (const vp of [
      { name: 'desktop', width: 1440, height: 900 },
      { name: 'mobile', width: 390, height: 844 },
    ]) {
      const ctx = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        colorScheme: theme,
      });
      await ctx.addInitScript((t) => localStorage.setItem('ik-theme', t), theme);
      const page = await ctx.newPage();
      await page.goto(await signInLink(api, secret));
      await page
        .waitForURL((u) => u.toString().startsWith(APP) && !u.hash.includes('access_token'), {
          timeout: 15000,
        })
        .catch(() => {});
      await page.waitForTimeout(1500);
      for (const s of shots) {
        await page.goto(APP + s.path);
        await page.waitForLoadState('networkidle').catch(() => {});
        await page.waitForTimeout(900);
        try {
          if (s.act) await s.act(page);
        } catch (e) {
          console.warn(
            `  ! ${s.name} (${theme}, ${vp.name}): ${(e as Error).message.split('\n')[0]}`,
          );
        }
        const file = join(OUT, `${s.name}-${theme}-${vp.name}.png`);
        await page.screenshot({ path: file, fullPage: !s.act });
        console.log(`  ✓ ${s.name}-${theme}-${vp.name}.png`);
        await page.keyboard.press('Escape').catch(() => {});
      }
      await ctx.close();
    }
  }
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
