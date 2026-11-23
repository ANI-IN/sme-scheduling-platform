// The filter bar of Upcoming classes and the Schedule board (Release 3, C13 and C14): one button per field, named by
// its visible text ("Cohort", or "Cohort (2)" with two chosen), opening a list of labelled checkboxes, with a search
// box when the list is long. Under the bar, each choice is a chip button named "Remove <value>", and Clear all
// removes every choice. Matching and the remembered choices are in lib/filters.ts.
import { useState } from 'react';
import { Popover as P } from 'radix-ui';
import { ChevronDown, X } from 'lucide-react';
import {
  chipsFor,
  countChosen,
  fieldOptions,
  toggleValue,
  withField,
  type FilterField,
  type FilterValues,
} from '@/lib/filters';
import { Button, Input, cn } from './ui';

/** A list longer than this gets a search box. */
export const SEARCH_FROM = 8;

export function FilterBar({
  fields,
  value,
  onChange,
}: {
  fields: FilterField[];
  value: FilterValues;
  onChange: (v: FilterValues) => void;
}) {
  const chips = chipsFor(fields, value);
  return (
    <div className="mb-4 space-y-2">
      <div role="group" aria-label="Filters" className="flex flex-wrap items-center gap-2">
        {fields.map((f) => (
          <FieldList key={f.key} field={f} value={value} onChange={onChange} />
        ))}
      </div>
      {chips.length > 0 && (
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
          <ul aria-label="Chosen filters" className="flex flex-wrap items-center gap-x-4 gap-y-2">
            {fields
              .filter((f) => (value[f.key] ?? []).length > 0)
              .map((f) => (
                <li key={f.key} className="flex flex-wrap items-center gap-1 text-sm">
                  <span className="text-xs text-muted-foreground">{f.label}:</span>
                  {chips
                    .filter((c) => c.key === f.key)
                    .map((c) => (
                      <button
                        key={c.value}
                        type="button"
                        // The visible value, with the action in front: "Remove Weekday cohort".
                        aria-label={`Remove ${c.label}`}
                        onClick={() => onChange(toggleValue(value, c.key, c.value, false))}
                        className="inline-flex max-w-full items-center gap-1 rounded-full border border-primary/40 bg-primary-soft px-2 py-0.5 text-xs font-medium text-foreground hover:bg-muted focus-visible:outline-2 focus-visible:outline-ring"
                      >
                        <span className="truncate">{c.label}</span>
                        <X className="h-3 w-3 shrink-0" aria-hidden />
                      </button>
                    ))}
                </li>
              ))}
          </ul>
          <Button size="sm" variant="ghost" onClick={() => onChange({})}>
            Clear all
          </Button>
        </div>
      )}
    </div>
  );
}

function FieldList({
  field,
  value,
  onChange,
}: {
  field: FilterField;
  value: FilterValues;
  onChange: (v: FilterValues) => void;
}) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState('');
  const chosen = value[field.key] ?? [];
  const n = countChosen({ [field.key]: chosen });
  const options = fieldOptions(field, chosen);
  const long = options.length > SEARCH_FROM;
  const q = search.trim().toLowerCase();
  const shown = q ? options.filter((o) => (o.label ?? o.value).toLowerCase().includes(q)) : options;
  return (
    <P.Root
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (!o) setSearch('');
      }}
    >
      <P.Trigger
        className={cn(
          'inline-flex h-8 shrink-0 items-center gap-1 rounded-md border px-2.5 text-sm font-medium whitespace-nowrap shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring',
          n > 0
            ? 'border-primary/60 bg-primary-soft text-foreground hover:bg-muted'
            : 'border-input bg-card text-foreground hover:bg-muted',
        )}
      >
        {field.label}
        {n > 0 && ` (${n})`}
        <ChevronDown className="h-3.5 w-3.5" aria-hidden />
      </P.Trigger>
      <P.Portal>
        <P.Content
          aria-label={field.label}
          align="start"
          sideOffset={4}
          collisionPadding={8}
          className="z-50 w-72 max-w-[calc(100vw-1rem)] rounded-md border border-border bg-card p-2 text-card-foreground shadow-md"
        >
          {long && (
            <Input
              type="search"
              aria-label={`Search ${field.label.toLowerCase()}`}
              placeholder="Search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="mb-2"
            />
          )}
          {options.length === 0 ? (
            <p className="px-1 py-2 text-sm text-muted-foreground">Nothing to choose yet.</p>
          ) : shown.length === 0 ? (
            <p className="px-1 py-2 text-sm text-muted-foreground">Nothing matches your search.</p>
          ) : (
            <ul className="max-h-64 space-y-0.5 overflow-y-auto">
              {shown.map((o) => (
                <li key={o.value}>
                  <label className="flex cursor-pointer items-center gap-2 rounded px-1.5 py-1 text-sm hover:bg-muted">
                    <input
                      type="checkbox"
                      className="h-4 w-4 shrink-0 rounded border-input accent-[var(--primary)]"
                      checked={chosen.includes(o.value)}
                      onChange={(e) =>
                        onChange(toggleValue(value, field.key, o.value, e.target.checked))
                      }
                    />
                    <span className="min-w-0 break-words">{o.label ?? o.value}</span>
                  </label>
                </li>
              ))}
            </ul>
          )}
          <div className="mt-2 flex items-center justify-between gap-2 border-t border-border pt-2">
            <Button
              size="sm"
              variant="ghost"
              disabled={n === 0}
              onClick={() => onChange(withField(value, field.key, []))}
            >
              Clear
            </Button>
            <Button size="sm" onClick={() => setOpen(false)}>
              Done
            </Button>
          </div>
        </P.Content>
      </P.Portal>
    </P.Root>
  );
}
