import type { CheckWarning } from '@/components/WarningsDialog';

/** A class week of a plan that is checked again after each change: `key` names it, `rev` counts its changes. */
export type Checkable = {
  key?: number;
  rev?: number;
  warnings: CheckWarning[];
  blocks?: string[];
  duplicate: boolean;
};
/** What check_plan answers for one class week. */
export type PlanCheck = { warnings: CheckWarning[]; blocks: string[] };

/**
 * Puts the answers of check_plan on the class weeks they were asked for. An answer is used only while its class
 * week is unchanged since it was sent: a later change has its own check on the way, so an older answer never
 * replaces a newer one, and a removed class week is skipped.
 */
export function applyPlanChecks<T extends Checkable>(
  rows: T[],
  sent: { key: number; rev: number }[],
  answers: PlanCheck[],
): T[] {
  const byKey = new Map(sent.map((s, i) => [s.key, { rev: s.rev, answer: answers[i] }]));
  return rows.map((r) => {
    const hit = r.key === undefined ? undefined : byKey.get(r.key);
    if (!hit?.answer || (r.rev ?? 0) !== hit.rev) return r;
    // The check covers an existing class week too ("Already planned"), as a block.
    return { ...r, warnings: hit.answer.warnings, blocks: hit.answer.blocks, duplicate: false };
  });
}
