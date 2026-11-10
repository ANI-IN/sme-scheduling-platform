// Checks the theme tokens in app/src/index.css against WCAG AA:
// 4.5:1 for text, 3:1 for control boundaries and focus rings (WCAG 1.4.3 and 1.4.11).
//   npm run contrast -w scripts
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const css = readFileSync(join(import.meta.dirname, '..', '..', 'app', 'src', 'index.css'), 'utf8');

function block(selector: string): Record<string, string> {
  const start = css.indexOf(`${selector} {`);
  const body = css.slice(start, css.indexOf('}', start));
  return Object.fromEntries(
    [...body.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})/gi)].map((m) => [m[1]!, m[2]!]),
  );
}

function lum(hex: string): number {
  const [r, g, b] = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
}
export function ratio(a: string, b: string): number {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x! + 0.05) / (y! + 0.05);
}

const text: [string, string][] = [
  ['foreground', 'background'],
  ['foreground', 'card'],
  ['foreground', 'muted'],
  ['muted-foreground', 'background'],
  ['muted-foreground', 'card'],
  ['muted-foreground', 'muted'],
  ['primary-foreground', 'primary'],
  ['primary-foreground', 'primary-hover'],
  ['destructive-foreground', 'destructive'],
  ['destructive-foreground', 'destructive-hover'],
  ['link', 'card'],
  ['link', 'background'],
  ['success-strong', 'success-soft'],
  ['warning-strong', 'warning-soft'],
  ['danger-strong', 'danger-soft'],
  ['info-strong', 'info-soft'],
  ['neutral-strong', 'neutral-soft'],
  ['accent-strong', 'accent-soft'],
  ['danger-strong', 'card'],
  ['sidebar-foreground', 'sidebar'],
  ['sidebar-active-foreground', 'sidebar-active'],
];
const ui: [string, string][] = [
  ['input', 'card'],
  ['ring', 'card'],
  ['ring', 'background'],
  ['primary', 'card'],
  ['destructive', 'card'],
];

let failed = 0;
const rows: string[] = ['| Theme | Pair | Ratio | Needed | Result |', '|---|---|---|---|---|'];
for (const [theme, sel] of [
  ['Light', ':root'],
  ['Dark', ':root.dark'],
] as const) {
  const t = block(sel);
  for (const [pairs, need] of [
    [text, 4.5],
    [ui, 3],
  ] as const) {
    for (const [fg, bg] of pairs) {
      const r = ratio(t[fg]!, t[bg]!);
      const ok = r >= need;
      if (!ok) failed++;
      rows.push(
        `| ${theme} | ${fg} on ${bg} | ${r.toFixed(2)} | ${need} | ${ok ? 'pass' : 'FAIL'} |`,
      );
    }
  }
}
console.log(rows.join('\n'));
console.log(failed ? `\n${failed} pair(s) below WCAG AA` : '\nAll pairs meet WCAG AA.');
process.exit(failed ? 1 : 0);
