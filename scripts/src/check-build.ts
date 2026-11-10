// Fails when a production build of the app contains the development sign in or other markers
// that must never ship. Run after `npm run build`.
//
//   npm run check-build -w scripts
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

const DIST = resolve(import.meta.dirname, '../../app/dist');
const FORBIDDEN = [
  'Local development only', // the development email link
  'email me a link',
  'DevSignIn',
  'Mailpit',
];

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

let files: string[];
try {
  files = walk(DIST).filter((f) => /\.(js|html|css)$/.test(f));
} catch {
  console.error('No production build found in app/dist. Run `npm run build` first.');
  process.exit(1);
}
const found = files.flatMap((f) => {
  const text = readFileSync(f, 'utf8');
  return FORBIDDEN.filter((m) => text.includes(m)).map((m) => `${f.slice(DIST.length + 1)}: ${m}`);
});
if (found.length) {
  console.error('The production build contains development only code:\n' + found.join('\n'));
  process.exit(1);
}
console.log(`Production build is clean (${files.length} files checked).`);
