// Lists every test scenario, straight from the test files, into docs/TEST_REPORT.md between the
// markers <!-- scenarios:start --> and <!-- scenarios:end -->, so the report never drifts from the tests.
//
//   npm run test-list -w scripts
//
// Database tests: each pgTAP check with its description (the last quoted text of the check).
// Screen tests: each Playwright test title. Unit tests: each `it` title.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '..', '..');
const REPORT = join(ROOT, 'docs', 'TEST_REPORT.md');
const DB = join(ROOT, 'supabase', 'tests', 'database');
const E2E = join(ROOT, 'e2e', 'tests');
const APP = join(ROOT, 'app', 'src');

const CHECK =
  /^select\s+(is|isnt|ok|throws_ok|throws_like|lives_ok|results_eq|set_eq|bag_eq|cmp_ok|matches|alike|is_empty)\s*\(/i;

/** The last single quoted SQL string in a statement ('' is a quote inside it). */
function lastString(stmt: string): string | null {
  const all = [...stmt.matchAll(/'((?:[^']|'')*)'/g)].map((m) => m[1]!.replace(/''/g, "'"));
  return all.length ? all[all.length - 1]! : null;
}

function dbChecks(file: string): string[] {
  const text = readFileSync(join(DB, file), 'utf8');
  const out: string[] = [];
  // Statements end with ";" at the end of a line (function bodies in $$ are skipped).
  let buf = '';
  let inBody = false;
  for (const line of text.split('\n')) {
    if (/^\s*--/.test(line) && !buf) continue;
    buf += line + '\n';
    if ((line.match(/\$\$/g) ?? []).length % 2 === 1) inBody = !inBody;
    // A statement ends with ";" (perhaps followed by a comment) or is a psql line such as \gset.
    const bare = line.replace(/'(?:[^']|'')*'/g, "''");
    if (!inBody && (/;\s*(--.*)?$/.test(bare) || /\\gset\s*$/.test(bare) || /^\s*\\/.test(line))) {
      const stmt = buf
        .split('\n')
        .filter((l) => !/^\s*--/.test(l))
        .join('\n')
        .trim();
      buf = '';
      if (CHECK.test(stmt)) out.push(lastString(stmt) ?? '(no description)');
    }
  }
  return out;
}

function titles(dir: string, file: string, fn: 'test' | 'it'): string[] {
  const text = readFileSync(join(dir, file), 'utf8');
  const re =
    fn === 'test'
      ? /\btest\(\s*(['"`])((?:\\.|(?!\1).)*)\1/gs
      : /\bit\(\s*(['"`])((?:\\.|(?!\1).)*)\1/gs;
  return [...text.matchAll(re)].map((m) => m[2]!.replace(/\\(.)/g, '$1'));
}

const walk = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? walk(join(dir, d.name)).map((f) => join(d.name, f)) : [d.name],
  );

/** Test names in the report's own words: no dashes (docs follow the same writing rules as the app). */
const plain = (t: string) =>
  t
    .replace(/\s+/g, ' ')
    .replace(/\s+[—–]\s+/g, ': ')
    .replace(/[—–]/g, ' to ');

const md: string[] = [];
let total = 0;
md.push('### Database tests (pgTAP)', '');
for (const f of readdirSync(DB)
  .filter((x) => x.endsWith('.sql'))
  .sort()) {
  const checks = dbChecks(f);
  total += checks.length;
  md.push(`<details><summary><code>${f}</code>: ${checks.length} checks</summary>`, '');
  checks.forEach((c, i) => md.push(`${i + 1}. ${plain(c)}`));
  md.push('', '</details>', '');
}
const dbTotal = total;
md.push('### Screen tests (Playwright scenarios)', '');
let screens = 0;
for (const f of readdirSync(E2E)
  .filter((x) => /scenarios\.spec\.ts$/.test(x))
  .sort()) {
  const t = titles(E2E, f, 'test');
  screens += t.length;
  md.push(`**\`e2e/tests/${f}\`** (${t.length})`, '');
  t.forEach((x, i) => md.push(`${i + 1}. ${plain(x)}`));
  md.push('');
}
md.push('### Unit tests (Vitest)', '');
let units = 0;
for (const f of walk(APP)
  .filter((x) => x.endsWith('.test.ts'))
  .sort()) {
  const t = titles(APP, f, 'it');
  units += t.length;
  md.push(`**\`app/src/${f.replace(/\\/g, '/')}\`** (${t.length})`, '');
  t.forEach((x, i) => md.push(`${i + 1}. ${plain(x)}`));
  md.push('');
}

const report = readFileSync(REPORT, 'utf8');
const start = '<!-- scenarios:start -->';
const end = '<!-- scenarios:end -->';
if (!report.includes(start) || !report.includes(end)) {
  console.error(`docs/TEST_REPORT.md needs the markers ${start} and ${end}.`);
  process.exit(1);
}
const body = [
  start,
  '',
  `Made by \`npm run test-list -w scripts\` from the test files: ${dbTotal} database checks, ${screens} screen scenarios and ${units} unit tests.`,
  '',
  ...md,
  end,
].join('\n');
writeFileSync(
  REPORT,
  report.slice(0, report.indexOf(start)) + body + report.slice(report.indexOf(end) + end.length),
);
console.log(
  `Listed ${dbTotal} database checks, ${screens} screen scenarios and ${units} unit tests.`,
);
