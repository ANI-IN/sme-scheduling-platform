import { describe, expect, it } from 'vitest';
import { applyPlanChecks } from './planCheck';

const row = (key: number, rev: number) => ({
  key,
  rev,
  warnings: [{ code: 'holiday', text: 'Old warning' }],
  blocks: [] as string[],
  duplicate: true,
});
const answer = { warnings: [{ code: 'unusual_hours', text: 'New warning' }], blocks: ['A block'] };

describe('applyPlanChecks', () => {
  it('puts the answer on the class week it was asked for', () => {
    const [a, b] = applyPlanChecks([row(1, 2), row(2, 0)], [{ key: 1, rev: 2 }], [answer]);
    expect(a).toMatchObject({ warnings: answer.warnings, blocks: ['A block'], duplicate: false });
    expect(b!.warnings[0]!.text).toBe('Old warning');
  });

  it('ignores an answer for a class week changed again since', () => {
    const [a] = applyPlanChecks([row(1, 3)], [{ key: 1, rev: 2 }], [answer]);
    expect(a!.warnings[0]!.text).toBe('Old warning');
    expect(a!.duplicate).toBe(true);
  });

  it('skips a class week removed meanwhile, and uses each answer in order', () => {
    const out = applyPlanChecks(
      [row(3, 1)],
      [
        { key: 2, rev: 1 },
        { key: 3, rev: 1 },
      ],
      [{ warnings: [], blocks: ['For 2'] }, answer],
    );
    expect(out).toHaveLength(1);
    expect(out[0]!.blocks).toEqual(['A block']);
  });
});
