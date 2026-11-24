// The Legend and help side panel of the Schedule board and Upcoming classes (owner, 24 November 2026, decision 344):
// what to show in the Legend tab, and remembering whether the panel is open, per person and page on this browser.
import type { LegendGroup } from '@/pages/boardBadges';

/** Words compared without case, spaces or punctuation, so "Waiting for an answer" matches "waiting for an answer." */
export const squashLabel = (s: string): string => s.toLowerCase().replace(/[^a-z0-9]+/g, '');

/**
 * The Legend's groups for a search and the "Only what's on this page" switch. An item stays when its label or its
 * meaning contains every word typed, and, with the switch on, when its label is shown on the page. Groups left empty
 * are dropped.
 */
export function filterLegend(
  groups: readonly LegendGroup[],
  query: string,
  onlyShown: boolean,
  shown: ReadonlySet<string>,
): LegendGroup[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const shownSquashed = new Set([...shown].map(squashLabel));
  return groups
    .map((g) => ({
      ...g,
      items: g.items.filter((i) => {
        const text = `${i.label} ${i.text}`.toLowerCase();
        if (!words.every((w) => text.includes(w))) return false;
        return !onlyShown || shownSquashed.has(squashLabel(i.label));
      }),
    }))
    .filter((g) => g.items.length > 0);
}

/** The one line meaning of a status or badge, by its label as shown, or undefined when the Legend has none. */
export function meaningOf(groups: readonly LegendGroup[], label: string): string | undefined {
  const k = squashLabel(label);
  for (const g of groups) for (const i of g.items) if (squashLabel(i.label) === k) return i.text;
  return undefined;
}

/** A stable id for a Legend item, so "What is this?" can scroll to it. */
export const legendItemId = (label: string): string => `legendItem_${squashLabel(label)}`;

/** The localStorage key of the panel's open or closed state for one page and one person. */
export const panelKey = (page: string, who: string): string => `helpPanel:${page}:${who}`;

/** Open the first time (nothing saved yet), then whatever the person chose last on this browser. */
export function readPanelOpen(saved: string | null): boolean {
  return saved !== 'closed';
}
