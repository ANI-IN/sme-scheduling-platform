/// <reference types="node" />
// Every picture a help guide or docs/SETUP_GUIDE.md points to must exist, so a guide never shows a
// broken image. The pictures are made by `npm run help:screenshots`.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP = join(__dirname, '..', '..');
const HELP = join(APP, 'src', 'help');
const SETUP = join(APP, '..', 'docs', 'SETUP_GUIDE.md');

const pictures = (text: string) =>
  [...text.matchAll(/!\[[^\]]*\]\(([^)]+\.png)\)/g)].map((m) => m[1]!);

describe('help pictures', () => {
  it('every picture in the help guides exists', () => {
    const missing = readdirSync(HELP)
      .filter((f) => f.endsWith('.md'))
      .flatMap((f) =>
        pictures(readFileSync(join(HELP, f), 'utf8'))
          .filter((p) => !existsSync(join(APP, 'public', p)))
          .map((p) => `${f}: ${p}`),
      );
    expect(missing).toEqual([]);
  });

  it('every picture in docs/SETUP_GUIDE.md exists', () => {
    const missing = pictures(readFileSync(SETUP, 'utf8')).filter(
      (p) => !existsSync(join(SETUP, '..', p)),
    );
    expect(missing).toEqual([]);
  });
});
