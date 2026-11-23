import { describe, expect, it } from 'vitest';
import {
  addIds,
  matchItems,
  moveActive,
  normalize,
  removeId,
  summary,
  toggleId,
  withPending,
} from './multiSelectLogic';

const people = [
  { id: 'a', label: 'Victor Palmer' },
  { id: 'b', label: 'José Ramírez', hint: 'not in use' },
  { id: 'c', label: 'Maya Rao' },
];

describe('normalize', () => {
  it('ignores case, accents and extra spaces', () => {
    expect(normalize('  José   RAMÍREZ ')).toBe('jose ramirez');
  });
});

describe('matchItems', () => {
  it('shows every item when nothing is typed', () => {
    expect(matchItems(people, '  ').map((p) => p.id)).toEqual(['a', 'b', 'c']);
  });
  it('matches every typed word, in any order, without accents', () => {
    expect(matchItems(people, 'ramirez jo').map((p) => p.id)).toEqual(['b']);
    expect(matchItems(people, 'ra').map((p) => p.id)).toEqual(['b', 'c']);
  });
  it('matches the hint too', () => {
    expect(matchItems(people, 'not in use').map((p) => p.id)).toEqual(['b']);
  });
  it('matches nothing when a word is missing', () => {
    expect(matchItems(people, 'maya palmer')).toEqual([]);
  });
});

describe('toggleId', () => {
  it('adds an item that is not chosen, at the end', () => {
    expect(toggleId(['a'], 'c')).toEqual({
      next: ['a', 'c'],
      change: { added: ['c'], removed: [] },
    });
  });
  it('removes an item that is chosen', () => {
    expect(toggleId(['a', 'c'], 'a')).toEqual({
      next: ['c'],
      change: { added: [], removed: ['a'] },
    });
  });
});

describe('addIds', () => {
  it('adds several at once, leaving out the ones already chosen and repeats', () => {
    expect(addIds(['a'], ['a', 'b', 'c', 'b'])).toEqual({
      next: ['a', 'b', 'c'],
      change: { added: ['b', 'c'], removed: [] },
    });
  });
});

describe('removeId', () => {
  it('removes one chip', () => {
    expect(removeId(['a', 'b'], 'b')).toEqual({
      next: ['a'],
      change: { added: [], removed: ['b'] },
    });
  });
  it('changes nothing for an item not chosen', () => {
    expect(removeId(['a'], 'z')).toEqual({ next: ['a'], change: { added: [], removed: [] } });
  });
});

describe('moveActive', () => {
  it('moves down and up, wrapping around', () => {
    expect(moveActive(-1, 3, 'ArrowDown')).toBe(0);
    expect(moveActive(0, 3, 'ArrowDown')).toBe(1);
    expect(moveActive(2, 3, 'ArrowDown')).toBe(0);
    expect(moveActive(0, 3, 'ArrowUp')).toBe(2);
    expect(moveActive(-1, 3, 'ArrowUp')).toBe(2);
    expect(moveActive(2, 3, 'ArrowUp')).toBe(1);
  });
  it('jumps to the first and last', () => {
    expect(moveActive(1, 3, 'Home')).toBe(0);
    expect(moveActive(1, 3, 'End')).toBe(2);
  });
  it('has no active option in an empty list', () => {
    expect(moveActive(0, 0, 'ArrowDown')).toBe(-1);
  });
});

describe('withPending', () => {
  it('shows the items being saved after the chosen ones, once', () => {
    expect(withPending(['a'], ['a', 'c'])).toEqual(['a', 'c']);
  });
});

describe('summary', () => {
  it('names the first choice and counts the rest', () => {
    expect(summary(people, [], 'Nobody yet')).toBe('Nobody yet');
    expect(summary(people, ['c'], 'Nobody yet')).toBe('Maya Rao');
    expect(summary(people, ['c', 'a', 'b'], 'Nobody yet')).toBe('Maya Rao and 2 more');
  });
});
