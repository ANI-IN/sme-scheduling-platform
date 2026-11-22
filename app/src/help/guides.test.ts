/// <reference types="node" />
// Every help guide is complete and reachable: it has a title, a summary, a group of the Help page and its own
// number, and every link to a guide (from a guide, a page, or the "?" next to a page title) opens one that exists.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { guideForPath } from '@/lib/helpLinks';
import { GUIDES, GUIDE_GROUPS, groupGuides, guideBySlug, searchGuides } from './guides';

const SRC = join(__dirname, '..');

/** Every app source file (pages, components and the guides), with its text. */
function sources(dir = SRC): { file: string; text: string }[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) return sources(p);
    if (!/\.(tsx?|md)$/.test(f) || /\.test\.tsx?$/.test(f)) return [];
    return [{ file: p.slice(SRC.length + 1), text: readFileSync(p, 'utf8') }];
  });
}

describe('help guides', () => {
  it('each guide has a title, a summary, a known group and its own number', () => {
    expect(GUIDES.length).toBeGreaterThan(0);
    for (const g of GUIDES) {
      expect(g.title, g.slug).not.toBe(g.slug);
      expect(g.summary, g.slug).not.toBe('');
      expect(GUIDE_GROUPS as readonly string[], g.slug).toContain(g.group);
      expect(g.body.length, g.slug).toBeGreaterThan(100);
    }
    const orders = GUIDES.map((g) => g.order);
    expect(new Set(orders).size).toBe(orders.length);
  });

  it('every guide is listed under a group of the Help page', () => {
    const listed = groupGuides(GUIDES).flatMap((x) => x.guides.map((g) => g.slug));
    expect(listed.sort()).toEqual(GUIDES.map((g) => g.slug).sort());
  });

  it('every link to a guide opens a guide that exists', () => {
    const broken = sources().flatMap(({ file, text }) =>
      [...text.matchAll(/["'`(]\/help\/([a-z0-9-]+)(?=["'`)#?])/g)]
        .map((m) => m[1]!)
        .filter((slug) => !guideBySlug(slug))
        .map((slug) => `${file}: /help/${slug}`),
    );
    expect(broken).toEqual([]);
  });

  it('the question mark on every page opens a guide that exists', () => {
    const pages = [
      '/',
      '/board',
      '/classes',
      '/requests',
      '/setup/modules',
      '/setup/modules/new',
      '/setup/standards',
      '/setup/instructors',
      '/setup/team',
      '/setup/domains',
      '/settings/automation',
      '/settings/messages',
      '/settings/testing',
      '/settings/connections',
      '/settings/admin',
      '/activity',
      '/somewhere-else',
    ];
    const missing = pages.filter((p) => !guideBySlug(guideForPath(p)));
    expect(missing).toEqual([]);
  });

  it('search finds a guide by its keywords as well as its text', () => {
    expect(searchGuides('beta list').map((g) => g.slug)).toContain('admins-and-beta-list');
    expect(searchGuides('clash').map((g) => g.slug)).toContain('fixing-problems');
    expect(searchGuides('login').map((g) => g.slug)).toContain('getting-started');
    expect(searchGuides('clash zzqxv')).toEqual([]);
  });
});
