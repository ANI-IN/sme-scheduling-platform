import { describe, expect, it } from 'vitest';
import {
  filterLegend,
  legendItemId,
  meaningOf,
  panelKey,
  readPanelOpen,
  squashLabel,
} from './helpPanel';
import { legendGroups } from '@/pages/boardBadges';

const groups = legendGroups();
const labels = (g: ReturnType<typeof filterLegend>) =>
  g.flatMap((x) => x.items.map((i) => i.label));

describe('filterLegend', () => {
  it('keeps everything with no search and the switch off', () => {
    expect(labels(filterLegend(groups, '', false, new Set()))).toEqual(labels(groups));
  });

  it('finds items by a word of their label or their meaning, without case', () => {
    expect(labels(filterLegend(groups, 'clash', false, new Set()))).toContain('Clash');
    const byMeaning = labels(filterLegend(groups, 'PUBLIC HOLIDAY', false, new Set()));
    expect(byMeaning).toContain('Holiday');
    expect(byMeaning).not.toContain('Clash');
  });

  it('needs every word typed', () => {
    expect(labels(filterLegend(groups, 'clash nothing-like-this', false, new Set()))).toEqual([]);
  });

  it('with Only what is on this page, keeps only the labels shown, matched without case or punctuation', () => {
    const shown = new Set(['confirmed', 'Waiting for an answer.', 'Clash']);
    expect(labels(filterLegend(groups, '', true, shown)).sort()).toEqual(
      ['Clash', 'Confirmed', 'Waiting for an answer'].sort(),
    );
  });

  it('drops groups left empty', () => {
    const g = filterLegend(groups, '', true, new Set(['Confirmed']));
    expect(g.map((x) => x.title)).toEqual(['Statuses']);
  });
});

describe('meaningOf and legendItemId', () => {
  it('gives the one line meaning of a label as shown', () => {
    expect(meaningOf(groups, 'clash')).toMatch(
      /^The instructor is in two classes at the same time\.$/,
    );
    expect(meaningOf(groups, 'Not a status')).toBeUndefined();
  });

  it('makes the same id for the same label however it is written', () => {
    expect(legendItemId('Waiting for an answer')).toBe(legendItemId('waiting for an answer.'));
    expect(squashLabel('Sooner class first')).toBe('soonerclassfirst');
  });
});

describe('the remembered choice', () => {
  it('opens the first time, then follows the last choice', () => {
    expect(readPanelOpen(null)).toBe(true);
    expect(readPanelOpen('closed')).toBe(false);
    expect(readPanelOpen('open')).toBe(true);
  });

  it('is kept per page and per person', () => {
    expect(panelKey('board', 'a@x')).not.toBe(panelKey('classes', 'a@x'));
    expect(panelKey('board', 'a@x')).not.toBe(panelKey('board', 'b@x'));
  });
});
