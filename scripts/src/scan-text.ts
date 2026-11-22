// Scans user facing text for the wording rules in docs/GLOSSARY.md:
// no dashes (— or –), no hyphenated words, no "e.g.", no internal names
// (allowed only on the Connections page) and no old class week status words.
// Checks app source (JSX text, string literals and template text that read as
// words), the help guides, the string literals in the latest definition of every
// database function (old status words, and dashes) and, if the local database is
// reachable, the setting labels and help stored in the database.
//
//   npm run scan-text -w scripts
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import ts from 'typescript';
import pg from 'pg';
import { latestSqlFunctions, sqlStringLiterals } from './sql-functions.ts';

const ROOT = resolve(import.meta.dirname, '../..');
const SRC = join(ROOT, 'app/src');
const MIGRATIONS = join(ROOT, 'supabase/migrations');
const DB = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';

/** Internal names users should not see. */
const BANNED: [RegExp, string][] = [
  [/\bWF\d+\b/, 'workflow code'],
  [/\bn8n\b/i, 'n8n'],
  [/\bUUID\b/i, 'UUID'],
  [/\bpayloads?\b/i, 'payload'],
  [/\btokens?\b/i, 'token'],
  [/\bkill switch\b/i, 'kill switch'],
  [/\bheartbeats?\b/i, 'heartbeat'],
  [/\bhourly check\b/i, 'hourly check'],
  [/\bseed(ed)?\b/i, 'seed'],
  [/\brankings?\b/i, 'ranking'],
];
const ALLOW_INTERNAL = [/settings[\\/]Connections\.tsx$/];
/**
 * Never shown to anyone, on any page (Release 3, B4, decision 313): there is no Sandbox, demo or test environment
 * any more. Internal names that keep the word (n8n credentials, tags, webhook paths) never reach a screen.
 */
const NEVER: [RegExp, string][] = [
  [/\bsandbox\b/i, 'Sandbox'],
  [/\bdemo\b/i, 'demo'],
  [/\btest environment\b/i, 'test environment'],
];
/**
 * Old words for the status of a class week (owner's item 1, docs/GLOSSARY.md). People only ever read Confirmed,
 * Waiting for an answer, Needs instructor, Proposed time, Not asked yet, Setup incomplete, Paused, Cancelled,
 * Completed and Break. An old word is flagged where it is a label: the whole text, the start of "Label: name" or
 * "Label (name)", a bold or quoted label, and (for the longer ones, which are never ordinary sentence words) anywhere
 * with its capital letter. The verb in a sentence ("We are asking the next instructor") is fine.
 */
const OLD_STATUS = [
  'Asking',
  'Asking now',
  'Being asked',
  'Ready to ask',
  'Not started yet',
  'Not started',
  'Setup not finished',
  'Needs an instructor',
  'Requests paused',
  'Waiting for a reply',
];
/** The old words that are labels wherever they appear with a capital letter. */
const OLD_STATUS_ANYWHERE = [
  'Ready to ask',
  'Not started yet',
  'Setup not finished',
  'Needs an instructor',
  'Requests paused',
  'Waiting for a reply',
];
/**
 * The old status word a text uses as a label, or nothing (the words are letters and spaces only, so they go into a
 * pattern as they are). `sql`: a piece of database text, where status codes such as 'Asking' are compared
 * everywhere, so only a piece joined to more text ('Asking ' || name) is a label.
 */
function oldStatus(text: string, sql = false): string | undefined {
  const t = text.replace(/\s+/g, ' ').trim();
  for (const label of OLD_STATUS) {
    if (sql ? t === label && t !== text : new RegExp(`^${label}[.:]?$`).test(t)) return label;
    if (new RegExp(`^${label}(?:: | \\()`).test(t)) return label;
    if (!sql && new RegExp(`(?:\\*\\*|["“'‘])${label}(?:\\*\\*|["”'’])`).test(t)) return label;
  }
  for (const label of OLD_STATUS_ANYWHERE) if (new RegExp(`\\b${label}\\b`).test(t)) return label;
  return undefined;
}
/**
 * Old status words still in a help guide that another change is rewriting (owner's item 1). They are listed as
 * warnings, not findings, until that change lands; remove an entry once its guide uses the new words.
 */
const OLD_STATUS_PENDING: Record<string, string[]> = {
  'app/src/help/common-questions.md': [
    'Setup not finished',
    'Not started yet',
    'Needs an instructor',
  ],
};
const pending: Finding[] = [];
/** Hyphenated words that are fine (none so far; add with a reason). */
const HYPHEN_OK = new Set<string>([]);

const TW =
  /^!?(?:[a-z0-9]+:)*-?(?:bg|text|border|rounded|p[xytrbl]?|m[xytrbl]?|w|h|min|max|flex|grid|gap|items|justify|font|shadow|ring|outline|space|overflow|inline|block|hidden|sr|whitespace|truncate|line|cursor|tabular|leading|tracking|z|top|left|right|bottom|inset|opacity|transition|duration|ease|animate|col|row|self|place|order|divide|underline|list|align|shrink|grow|basis|aspect|object|pointer|select|resize|fill|stroke|translate|scale|rotate|origin|size|absolute|relative|fixed|sticky|last|first|group|peer|data|aria|dark|break|decoration|backdrop|blur|contents|table|caption|mx|sm|md|lg|xl)(?:-|$|\[)/;

type Finding = { where: string; text: string; problem: string };
const findings: Finding[] = [];

function looksLikeClasses(s: string): boolean {
  const toks = s.trim().split(/\s+/).filter(Boolean);
  if (toks.length === 0) return true;
  return toks.filter((t) => TW.test(t)).length / toks.length >= 0.5;
}

function check(where: string, text: string, internalOk: boolean) {
  const t = text.replace(/\s+/g, ' ').trim();
  if (/[—–]/.test(t)) findings.push({ where, text: t, problem: 'dash' });
  if (!t || !/[A-Za-z]/.test(t)) return;
  if (/\be\.g\./i.test(t)) findings.push({ where, text: t, problem: 'e.g.' });
  for (const m of t.matchAll(/\b[A-Za-z]+(?:-[A-Za-z]+)+\b/g)) {
    if (!HYPHEN_OK.has(m[0].toLowerCase()))
      findings.push({ where, text: t, problem: `hyphen "${m[0]}"` });
  }
  for (const [re, name] of NEVER) if (re.test(t)) findings.push({ where, text: t, problem: name });
  const old = oldStatus(t);
  if (old) {
    const f = { where, text: t, problem: `old status word "${old}"` };
    if (OLD_STATUS_PENDING[where.replace(/:\d+$/, '')]?.includes(old)) pending.push(f);
    else findings.push(f);
  }
  if (!internalOk)
    for (const [re, name] of BANNED)
      if (re.test(t)) findings.push({ where, text: t, problem: `internal name "${name}"` });
}

/** JSX attributes whose values are read by people. */
const TEXT_ATTRS = new Set([
  'title',
  'label',
  'placeholder',
  'description',
  'hint',
  'aria-label',
  'alt',
  'confirmLabel',
  'body',
]);
/** Calls whose string arguments are identifiers, not text. */
const CODE_CALLS =
  /^(rpc|from|select|eq|neq|in|or|order|is|gte|lte|gt|lt|filter|channel|on|get|set|has|delete|startsWith|endsWith|includes|split|join|replace|test|match|getItem|setItem|removeItem|toFormat|fromFormat|fromISO|setZone|useSearchParams|querySelector|addEventListener|cn|createElement|matchMedia)$/;

function isUserFacing(
  node: ts.StringLiteral | ts.NoSubstitutionTemplateLiteral | ts.TemplateLiteralLikeNode,
) {
  let p: ts.Node = node.parent;
  // climb through templates, conditionals, parentheses and binary +/??/||
  while (
    ts.isTemplateSpan(p) ||
    ts.isTemplateExpression(p) ||
    ts.isConditionalExpression(p) ||
    ts.isParenthesizedExpression(p) ||
    ts.isAsExpression(p) ||
    (ts.isBinaryExpression(p) &&
      [
        ts.SyntaxKind.PlusToken,
        ts.SyntaxKind.QuestionQuestionToken,
        ts.SyntaxKind.BarBarToken,
      ].includes(p.operatorToken.kind))
  )
    p = p.parent;
  if (ts.isImportDeclaration(p) || ts.isExportDeclaration(p)) return false;
  if (ts.isExternalModuleReference(p)) return false;
  if (ts.isLiteralTypeNode(p)) return false;
  if (ts.isElementAccessExpression(p)) return false;
  if (ts.isCaseClause(p)) return false;
  if (ts.isPropertyAssignment(p) && p.name === node) return false;
  if (ts.isBinaryExpression(p)) return false; // comparisons: a === 'Done'
  if (ts.isJsxAttribute(p) || (ts.isJsxExpression(p) && ts.isJsxAttribute(p.parent))) {
    const attr = ts.isJsxAttribute(p) ? p : (p.parent as ts.JsxAttribute);
    return TEXT_ATTRS.has(attr.name.getText());
  }
  if (ts.isCallExpression(p)) {
    const callee = p.expression;
    const name = ts.isPropertyAccessExpression(callee) ? callee.name.text : callee.getText();
    if (CODE_CALLS.test(name)) return false;
  }
  if (ts.isArrayLiteralExpression(p)) {
    // query keys and lists of codes: ['request', 'previews']
    const gp = p.parent;
    if (ts.isPropertyAssignment(gp) && /queryKey|select|columns|groups/.test(gp.name.getText()))
      return false;
  }
  return true;
}

function scanFile(file: string) {
  const src = readFileSync(file, 'utf8');
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const internalOk = ALLOW_INTERNAL.some((r) => r.test(file));
  const rel = relative(ROOT, file).replaceAll('\\', '/');
  const at = (n: ts.Node) => `${rel}:${sf.getLineAndCharacterOfPosition(n.getStart()).line + 1}`;
  const visit = (n: ts.Node) => {
    if (ts.isJsxText(n)) {
      check(at(n), n.text, internalOk);
    } else if (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) {
      const s = n.text;
      if (/\s/.test(s) && !looksLikeClasses(s) && isUserFacing(n)) check(at(n), s, internalOk);
      else if (
        !/\s/.test(s) &&
        (/[—–]/.test(s) ||
          /^[A-Z][a-z]+-[a-z]/.test(s) ||
          /^(sandbox|demo)$/i.test(s) ||
          OLD_STATUS.includes(s)) &&
        isUserFacing(n)
      )
        check(at(n), s, internalOk);
    } else if (ts.isTemplateExpression(n)) {
      const parts = [n.head.text, ...n.templateSpans.map((s) => s.literal.text)].join(' x ');
      if (!looksLikeClasses(parts) && isUserFacing(n.head)) check(at(n), parts, internalOk);
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
}

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) return walk(p);
    if (!/\.tsx?$/.test(f) || /\.test\.tsx?$/.test(f) || /database\.types\.ts$/.test(f)) return [];
    return [p];
  });
}

for (const f of walk(SRC)) scanFile(f);

// Help guides (Markdown): every line after the "---" that ends the title block.
for (const f of readdirSync(join(SRC, 'help')).filter((x) => x.endsWith('.md'))) {
  const rel = `app/src/help/${f}`;
  const lines = readFileSync(join(SRC, 'help', f), 'utf8').split(/\r?\n/);
  lines.forEach((line, n) => {
    // Links and picture addresses are code, not text.
    const text = line.replace(/\]\([^)]*\)/g, ']').replace(/^---$/, '');
    if (text.trim()) check(`${rel}:${n + 1}`, text, false);
  });
}

// Text the database writes for people (messages to the team, task titles, reasons): the string literals in the
// latest definition of every function, for the old status words only (plain.ts handles the rest).
function sqlLiterals(body: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < body.length; i++) {
    // A comment runs to the end of its line (and may hold an apostrophe that is not a quote).
    if (body.startsWith('--', i)) {
      const end = body.indexOf('\n', i);
      i = end === -1 ? body.length : end;
    } else if (body[i] === "'") {
      let lit = '';
      for (i++; i < body.length; i++) {
        if (body[i] === "'" && body[i + 1] === "'") {
          lit += "'";
          i++;
        } else if (body[i] === "'") break;
        else lit += body[i];
      }
      out.push(lit);
    }
  }
  return out;
}
const functions = new Map<string, { file: string; body: string }>();
for (const f of readdirSync(MIGRATIONS)
  .filter((x) => x.endsWith('.sql'))
  .sort()) {
  const sql = readFileSync(join(MIGRATIONS, f), 'utf8');
  for (const m of sql.matchAll(
    /create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\(([^)]*)\)[\s\S]*?\bas\s+\$(\w*)\$([\s\S]*?)\$\3\$/gi,
  ))
    functions.set(`${m[1]!.toLowerCase()}(${m[2]!.replace(/\s+/g, ' ').trim()})`, {
      file: f,
      body: m[4]!,
    });
}
for (const [name, { file, body }] of functions)
  for (const lit of sqlLiterals(body)) {
    const old = oldStatus(lit, true);
    if (old)
      findings.push({
        where: `supabase/migrations/${file} ${name}`,
        text: lit,
        problem: `old status word "${old}"`,
      });
  }
// Words the database writes (task titles, alerts, Activity history, errors, answer pages): every string literal in
// the latest definition of each SQL function in supabase/migrations. Only dashes are checked here, as the other rules
// still have database values that the app rewrites (app/src/lib/plain.ts).
const SQL_DASH_OK = new Set(['private.plain_message_text']); // the function that removes dashes
for (const f of latestSqlFunctions(join(ROOT, 'supabase/migrations'))) {
  const name = f.key.split('(')[0]!;
  if (SQL_DASH_OK.has(name)) continue;
  for (const s of sqlStringLiterals(f.body))
    // a dash, or a hyphen with a space on each side between words ("QA - Databases")
    if (/[—–]|\w\s+-\s+\w/.test(s.text))
      findings.push({
        where: `supabase/migrations/${f.file}:${f.bodyLine + s.offsetLine} (${name})`,
        text: s.text.replace(/\s+/g, ' ').trim(),
        problem: 'dash',
      });
}

// Text stored in the database and shown as is.
try {
  const db = new pg.Client({ connectionString: DB });
  await db.connect();
  const { rows } = await db.query<{ key: string; label: string; help: string | null }>(
    'select key, label, help from public.setting_definition order by key',
  );
  for (const r of rows) {
    check(`setting_definition.${r.key}.label`, r.label, false);
    if (r.help) check(`setting_definition.${r.key}.help`, r.help, false);
  }
  await db.end();
} catch (e) {
  console.warn(`(database text not checked: ${(e as Error).message})`);
}

for (const f of pending)
  console.warn(
    `(waiting for the help rewrite) ${f.where}  [${f.problem}]  ${f.text.slice(0, 100)}`,
  );
if (findings.length === 0) {
  console.log(
    'No dashes, hyphenated words, "e.g.", internal names, old status words or Sandbox, demo or test environment wording found in user facing text.',
  );
} else {
  for (const f of findings) console.log(`${f.where}  [${f.problem}]  ${f.text.slice(0, 140)}`);
  console.log(`\n${findings.length} finding(s).`);
  process.exitCode = 1;
}
