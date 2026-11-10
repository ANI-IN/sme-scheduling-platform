import { X } from 'lucide-react';
import type { TeamMember } from '@/lib/data';
import { Select } from './ui';

/** Selected people as removable chips, plus a dropdown to add someone. */
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
  onAdd: (id: string) => void;
  onRemove: (id: string) => void;
  addLabel?: string;
  emptyText?: string;
}) {
  const byId = new Map(people.map((p) => [p.id, p]));
  const available = people.filter((p) => p.active && !selected.includes(p.id));
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-1.5">
        {selected.length === 0 && (
          <span className="text-sm text-muted-foreground">{emptyText}</span>
        )}
        {selected.map((id) => (
          <span
            key={id}
            className="inline-flex items-center gap-1 rounded-full border border-border bg-muted py-0.5 pr-1 pl-2.5 text-sm"
          >
            {byId.get(id)?.name ?? 'Unknown person'}
            <button
              type="button"
              onClick={() => onRemove(id)}
              className="rounded-full p-0.5 text-muted-foreground hover:bg-card hover:text-foreground"
              aria-label={`Remove ${byId.get(id)?.name ?? 'this person'}`}
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </span>
        ))}
      </div>
      <Select
        value=""
        onChange={(e) => e.target.value && onAdd(e.target.value)}
        className="w-64"
        aria-label={addLabel}
        disabled={available.length === 0}
      >
        <option value="">{available.length ? addLabel : 'Everyone is already added'}</option>
        {available.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </Select>
    </div>
  );
}
