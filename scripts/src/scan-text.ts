// Scans user facing text for the wording rules in docs/GLOSSARY.md:
// no dashes (— or –), no hyphenated words, no "e.g.", and no internal names
// (allowed only on the Connections page). Checks app source (JSX text, string
// literals and template text that read as words) and, if the local database is
// reachable, the setting labels and help stored in the database.
//
//   npm run scan-text -w scripts
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import ts from 'typescript';
import pg from 'pg';

const ROOT = resolve(import.meta.dirname, '../..');
const SRC = join(ROOT, 'app/src');
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
      else if (!/\s/.test(s) && (/[—–]/.test(s) || /^[A-Z][a-z]+-[a-z]/.test(s)) && isUserFacing(n))
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

if (findings.length === 0) {
  console.log('No dashes, hyphenated words, "e.g." or internal names found in user facing text.');
} else {
  for (const f of findings) console.log(`${f.where}  [${f.problem}]  ${f.text.slice(0, 140)}`);
  console.log(`\n${findings.length} finding(s).`);
  process.exitCode = 1;
}
