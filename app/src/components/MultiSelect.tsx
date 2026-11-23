// A real multi select field (batch 4, B11): the chosen items as chips with a remove button, a search box, and a list
// to tick several items from without closing it. Used for owners and operations teams, and made to be reused by
// filters: it only knows items with an ID and a label.
//
// Accessibility: the search box is a combobox with its own name, the list is a listbox that allows several choices
// (each option says whether it is selected), and each chip's button is named "Remove <label>". Keys: Down and Up
// move through the list (opening it), Home and End jump, Enter ticks or unticks, Escape closes the list or clears
// the search, and Backspace in an empty search removes the last chip.
import { useId, useRef, useState, type KeyboardEvent } from 'react';
import { Check, ChevronDown, X } from 'lucide-react';
import { cn } from './ui';
import {
  addIds,
  matchItems,
  moveActive,
  removeId,
  toggleId,
  withPending,
  type MultiSelectChange,
  type MultiSelectItem,
} from './multiSelectLogic';

export type { MultiSelectChange, MultiSelectItem } from './multiSelectLogic';

export function MultiSelect({
  label,
  items,
  value,
  onChange,
  placeholder = 'Search',
  emptyText,
  noMatchText = 'Nothing matches',
  showLabel = false,
  disabled,
  className,
}: {
  /** The name of the search box (shown above it with showLabel, otherwise read by screen readers only). */
  label: string;
  /** Every choice, including the selected ones (their labels name the chips). */
  items: readonly MultiSelectItem[];
  /** The selected IDs, in the order chosen. */
  value: readonly string[];
  /**
   * Called with the new list and what changed. Return a promise while saving: the items being added show as chosen
   * until it settles, so nothing is added twice.
   */
  onChange: (next: string[], change: MultiSelectChange) => void | Promise<unknown>;
  placeholder?: string;
  /** Shown instead of chips when nothing is selected. */
  emptyText?: string;
  noMatchText?: string;
  showLabel?: boolean;
  disabled?: boolean;
  className?: string;
}) {
  const id = useId();
  const listId = `${id}-list`;
  const inputRef = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const [pending, setPending] = useState<string[]>([]);
  const chosen = withPending(value, pending);
  const byId = new Map(items.map((i) => [i.id, i]));
  const shown = matchItems(items, query);
  const addable = shown.filter((i) => !i.disabled && !chosen.includes(i.id));

  function send(r: { next: string[]; change: MultiSelectChange }) {
    if (r.change.added.length === 0 && r.change.removed.length === 0) return;
    const out = onChange(r.next, r.change);
    if (out && typeof (out as Promise<unknown>).finally === 'function' && r.change.added.length) {
      const added = r.change.added;
      setPending((p) => [...p, ...added]);
      void (out as Promise<unknown>)
        .catch(() => undefined)
        .finally(() => setPending((p) => p.filter((x) => !added.includes(x))));
    }
  }

  const toggle = (item: MultiSelectItem) => {
    if (item.disabled && !chosen.includes(item.id)) return;
    send(toggleId(chosen, item.id));
  };

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      setOpen(true);
      setActive((a) => moveActive(a, shown.length, e.key as 'ArrowDown' | 'ArrowUp'));
    } else if ((e.key === 'Home' || e.key === 'End') && open && shown.length) {
      e.preventDefault();
      setActive(moveActive(active, shown.length, e.key));
    } else if (e.key === 'Enter') {
      if (open && shown[active]) {
        e.preventDefault();
        toggle(shown[active]);
      }
    } else if (e.key === 'Escape') {
      if (open) {
        e.preventDefault();
        setOpen(false);
      } else if (query) {
        e.preventDefault();
        setQuery('');
      }
    } else if (e.key === 'Backspace' && !query && chosen.length) {
      send(removeId(chosen, chosen[chosen.length - 1]!));
    }
  }

  const optionId = (i: number) => `${id}-option-${i}`;
  const activeItem = open ? shown[active] : undefined;

  return (
    <div
      className={cn('relative space-y-2', className)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setOpen(false);
      }}
    >
      {showLabel && (
        <label htmlFor={`${id}-input`} className="block text-sm font-medium text-foreground">
          {label}
        </label>
      )}
      <div className="flex flex-wrap gap-1.5">
        {chosen.length === 0 && emptyText && (
          <span className="text-sm text-muted-foreground">{emptyText}</span>
        )}
        {chosen.map((x) => {
          const name = byId.get(x)?.label ?? 'Unknown';
          return (
            <span
              key={x}
              className={cn(
                'inline-flex items-center gap-1 rounded-full border border-border bg-muted py-0.5 pr-1 pl-2.5 text-sm',
                pending.includes(x) && 'opacity-60',
              )}
            >
              {name}
              <button
                type="button"
                disabled={disabled}
                onClick={() => send(removeId(chosen, x))}
                className="rounded-full p-0.5 text-muted-foreground hover:bg-card hover:text-foreground disabled:opacity-50"
                aria-label={`Remove ${name}`}
              >
                <X className="h-3.5 w-3.5" aria-hidden />
              </button>
            </span>
          );
        })}
      </div>
      <div className="relative w-full max-w-sm">
        <input
          ref={inputRef}
          id={`${id}-input`}
          type="text"
          role="combobox"
          aria-label={showLabel ? undefined : label}
          aria-expanded={open}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={activeItem ? optionId(active) : undefined}
          autoComplete="off"
          disabled={disabled}
          placeholder={placeholder}
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
            setActive(e.target.value ? 0 : -1);
          }}
          onFocus={() => setOpen(true)}
          onClick={() => setOpen(true)}
          onKeyDown={onKeyDown}
          className="h-9 w-full rounded-md border border-input bg-card py-1.5 pr-8 pl-2.5 text-sm text-foreground placeholder:text-muted-foreground focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-ring disabled:cursor-not-allowed disabled:bg-muted"
        />
        <ChevronDown
          className="pointer-events-none absolute top-1/2 right-2.5 h-4 w-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        {open && !disabled && (
          <div className="absolute z-30 mt-1 w-full rounded-md border border-border bg-card shadow-lg">
            <ul
              id={listId}
              role="listbox"
              aria-label={label}
              aria-multiselectable="true"
              className="max-h-60 overflow-y-auto py-1"
            >
              {shown.map((item, i) => {
                const selected = chosen.includes(item.id);
                return (
                  <li
                    key={item.id}
                    id={optionId(i)}
                    role="option"
                    aria-selected={selected}
                    aria-disabled={item.disabled && !selected ? true : undefined}
                    // Keep the focus in the search box, so several can be ticked in a row.
                    onMouseDown={(e) => e.preventDefault()}
                    onMouseEnter={() => setActive(i)}
                    onClick={() => toggle(item)}
                    className={cn(
                      'flex cursor-pointer items-center gap-2 px-3 py-1.5 text-sm',
                      i === active && 'bg-muted',
                      item.disabled && !selected && 'cursor-not-allowed opacity-50',
                    )}
                  >
                    <span
                      className={cn(
                        'flex h-4 w-4 shrink-0 items-center justify-center rounded border',
                        selected
                          ? 'border-primary bg-primary text-primary-foreground'
                          : 'border-input',
                      )}
                      aria-hidden
                    >
                      {selected && <Check className="h-3 w-3" />}
                    </span>
                    <span className="min-w-0 truncate">{item.label}</span>
                    {item.hint && (
                      <span className="ml-auto shrink-0 text-xs text-muted-foreground">
                        {item.hint}
                      </span>
                    )}
                  </li>
                );
              })}
              {shown.length === 0 && (
                <li role="presentation" className="px-3 py-1.5 text-sm text-muted-foreground">
                  {noMatchText}
                </li>
              )}
            </ul>
            {addable.length > 1 && (
              <div className="border-t border-border p-1">
                <button
                  type="button"
                  className="w-full rounded px-2 py-1 text-left text-sm font-medium text-link hover:bg-muted"
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => {
                    send(
                      addIds(
                        chosen,
                        addable.map((i) => i.id),
                      ),
                    );
                    setQuery('');
                    inputRef.current?.focus();
                  }}
                >
                  Add all {addable.length} shown
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
