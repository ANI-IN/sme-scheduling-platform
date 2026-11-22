// Reads supabase/migrations in order and returns the latest definition of every SQL function that still exists
// (a later "create or replace" wins, a later "drop function" removes it). Used by scan-text.ts to check the words
// in SQL string literals, which reach people as task titles, notes, messages and errors.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export type SqlFunction = {
  /** schema.name(arg types) */
  key: string;
  file: string;
  /** 1 based line of "create" in the file */
  line: number;
  /** text between the $$ quotes */
  body: string;
  /** line of the first body character */
  bodyLine: number;
  /** the whole statement, from "create" to the semicolon after the body */
  statement: string;
};

const ALIAS: Record<string, string> = {
  int: 'integer',
  int4: 'integer',
  int8: 'bigint',
  bool: 'boolean',
  'character varying': 'varchar',
  'timestamp with time zone': 'timestamptz',
};

/** Splits on commas that are not inside brackets. */
function splitTop(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = '';
  for (const ch of s) {
    if (ch === '(' || ch === '[') depth++;
    if (ch === ')' || ch === ']') depth--;
    if (ch === ',' && depth === 0) {
      out.push(cur);
      cur = '';
    } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out;
}

/** Input argument types only, the way Postgres identifies a function. */
function argTypes(args: string, named: boolean): string {
  const types: string[] = [];
  for (const raw of splitTop(args)) {
    let a = raw
      .replace(/\s+(default|=)\s[\s\S]*$/i, '')
      .trim()
      .toLowerCase()
      .replace(/\s+/g, ' ');
    if (!a) continue;
    const mode = /^(in|out|inout|variadic)\s/.exec(a);
    if (mode) {
      if (mode[1] === 'out') continue;
      a = a.slice(mode[0].length);
    }
    if (named) {
      const parts = a.split(' ');
      if (parts.length > 1 && !ALIAS[a]) a = parts.slice(1).join(' ');
    }
    types.push(ALIAS[a] ?? a);
  }
  return types.join(', ');
}

function lineAt(text: string, index: number): number {
  let n = 1;
  for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) n++;
  return n;
}

/** \`before\`: only the migrations whose file name sorts before it. */
export function latestSqlFunctions(migrationsDir: string, before?: string): SqlFunction[] {
  const latest = new Map<string, SqlFunction>();
  const files = readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql') && (!before || f < before))
    .sort();
  for (const file of files) {
    const text = readFileSync(join(migrationsDir, file), 'utf8');
    // Statements outside $$ bodies: walk the file, jumping over bodies, comments and plain strings.
    const re =
      /create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+([a-z_][\w.]*)\s*\(|drop\s+(?:function|procedure)\s+(?:if\s+exists\s+)?([a-z_][\w.]*)\s*\(/gi;
    let i = 0;
    while (i < text.length) {
      const ch = text[i];
      if (ch === '-' && text[i + 1] === '-') {
        const e = text.indexOf('\n', i);
        i = e < 0 ? text.length : e + 1;
        continue;
      }
      if (ch === '/' && text[i + 1] === '*') {
        const e = text.indexOf('*/', i + 2);
        i = e < 0 ? text.length : e + 2;
        continue;
      }
      if (ch === "'") {
        let j = i + 1;
        while (j < text.length) {
          if (text[j] === "'" && text[j + 1] === "'") j += 2;
          else if (text[j] === "'") break;
          else j++;
        }
        i = j + 1;
        continue;
      }
      if (ch === '$' && text[i + 1] === '$') {
        const e = text.indexOf('$$', i + 2);
        i = e < 0 ? text.length : e + 2;
        continue;
      }
      re.lastIndex = i;
      const m = re.exec(text);
      if (!m || m.index !== i) {
        i++;
        continue;
      }
      // the argument list: up to the matching bracket
      let depth = 1;
      let j = m.index + m[0].length;
      const argStart = j;
      while (j < text.length && depth > 0) {
        if (text[j] === '-' && text[j + 1] === '-') {
          const e = text.indexOf('\n', j);
          j = e < 0 ? text.length : e;
          continue;
        }
        if (text[j] === '(') depth++;
        else if (text[j] === ')') depth--;
        j++;
      }
      const args = text.slice(argStart, j - 1).replace(/--[^\n]*/g, '');
      const name = (m[1] ?? m[2])!.toLowerCase();
      const qualified = name.includes('.') ? name : `public.${name}`;
      if (m[2]) {
        latest.delete(`${qualified}(${argTypes(args, false)})`);
        i = j;
        continue;
      }
      const key = `${qualified}(${argTypes(args, true)})`;
      const open = text.indexOf('$$', j);
      const close = open < 0 ? -1 : text.indexOf('$$', open + 2);
      if (open < 0 || close < 0) {
        i = j;
        continue;
      }
      const semi = text.indexOf(';', close + 2);
      const end = semi < 0 ? close + 2 : semi + 1;
      latest.set(key, {
        key,
        file,
        line: lineAt(text, m.index),
        body: text.slice(open + 2, close),
        bodyLine: lineAt(text, open + 2),
        statement: text.slice(m.index, end),
      });
      i = end;
    }
  }
  return [...latest.values()];
}

/** The string literals in a PL/pgSQL or SQL body, with their line numbers, skipping comments. */
export function sqlStringLiterals(body: string): { text: string; offsetLine: number }[] {
  const out: { text: string; offsetLine: number }[] = [];
  let line = 0;
  let i = 0;
  while (i < body.length) {
    const ch = body[i];
    if (ch === '\n') {
      line++;
      i++;
      continue;
    }
    if (ch === '-' && body[i + 1] === '-') {
      const e = body.indexOf('\n', i);
      i = e < 0 ? body.length : e;
      continue;
    }
    if (ch === '/' && body[i + 1] === '*') {
      const e = body.indexOf('*/', i + 2);
      const end = e < 0 ? body.length : e + 2;
      for (let k = i; k < end; k++) if (body[k] === '\n') line++;
      i = end;
      continue;
    }
    if (ch === "'") {
      const startLine = line;
      let j = i + 1;
      let s = '';
      while (j < body.length) {
        if (body[j] === "'" && body[j + 1] === "'") {
          s += "'";
          j += 2;
        } else if (body[j] === "'") break;
        else {
          if (body[j] === '\n') line++;
          s += body[j];
          j++;
        }
      }
      out.push({ text: s, offsetLine: startLine });
      i = j + 1;
      continue;
    }
    i++;
  }
  return out;
}
