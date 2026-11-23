import type { TeamMember } from '@/lib/data';
import { MultiSelect } from './MultiSelect';

/**
 * Team members as a multi select (batch 4, B11): the chosen people as chips with a remove button, a search box, and
 * a list to tick several people from at once. People without access only show while they are chosen.
 */
export function PeoplePicker({
  people,
  selected,
  onAdd,
  onRemove,
  addLabel = 'Add a person',
  emptyText = 'Nobody yet.',
}: {
  people: TeamMember[];
  selected: string[];
  /** Saves the people just added (one or several). Return the save, so they show as added while it runs. */
  onAdd: (ids: string[]) => void | Promise<unknown>;
  onRemove: (id: string) => void | Promise<unknown>;
  addLabel?: string;
  emptyText?: string;
}) {
  const items = people
    .filter((p) => (p.active && !p.access_removed_at) || selected.includes(p.id))
    .map((p) => ({ id: p.id, label: p.name, disabled: !p.active || !!p.access_removed_at }));
  return (
    <MultiSelect
      label={addLabel}
      placeholder="Search people"
      noMatchText="Nobody matches"
      items={items}
      value={selected}
      emptyText={emptyText}
      onChange={(_, change) => {
        if (change.added.length) return onAdd(change.added);
        if (change.removed[0]) return onRemove(change.removed[0]);
      }}
    />
  );
}
