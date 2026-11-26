/// <reference types="node" />
// Every picture a help guide, the README or a document points to must exist, so none shows a broken
// image. The help pictures are made by `npm run help:screenshots`.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP = join(__dirname, '..', '..');
const HELP = join(APP, 'src', 'help');
const ROOT = join(APP, '..');
const DOCS = join(ROOT, 'docs');

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

  it('every picture in the README and docs exists', () => {
    const missing = ['README.md', ...readdirSync(DOCS).map((f) => `docs/${f}`)]
      .filter((f) => f.endsWith('.md'))
      .flatMap((f) =>
        pictures(readFileSync(join(ROOT, f), 'utf8'))
          .filter((p) => !existsSync(join(ROOT, f, '..', p)))
          .map((p) => `${f}: ${p}`),
      );
    expect(missing).toEqual([]);
  });
});
