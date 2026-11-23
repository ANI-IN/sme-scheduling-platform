// The filter bar names every control by its visible text: a button per field, a labelled checkbox per choice, a
// chip named "Remove <value>" per choice, and Clear all.
import { useState } from 'react';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import type { FilterField, FilterValues } from '@/lib/filters';
import { FilterBar, SEARCH_FROM } from './FilterBar';

beforeAll(() => {
  // The list is placed next to its button with a size watcher jsdom does not have.
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver;
});

afterEach(cleanup);

const many = Array.from({ length: SEARCH_FROM + 2 }, (_, i) => ({ value: `Cohort ${i + 1}` }));
const FIELDS: FilterField[] = [
  { key: 'cohort', label: 'Cohort', options: many },
  {
    key: 'status',
    label: 'Status',
    options: [{ value: 'Confirmed' }, { value: 'Paused' }],
  },
];

function Harness({ start = {} }: { start?: FilterValues }) {
  const [v, setV] = useState<FilterValues>(start);
  return (
    <>
      <FilterBar fields={FIELDS} value={v} onChange={setV} />
      <output data-testid="value">{JSON.stringify(v)}</output>
    </>
  );
}
const value = () => JSON.parse(screen.getByTestId('value').textContent!) as FilterValues;

describe('FilterBar', () => {
  it('has a button per field and no chips or Clear all while nothing is chosen', () => {
    render(<Harness />);
    const bar = screen.getByRole('group', { name: 'Filters' });
    expect(within(bar).getByRole('button', { name: 'Cohort' })).toBeInTheDocument();
    expect(within(bar).getByRole('button', { name: 'Status' })).toBeInTheDocument();
    expect(screen.queryByRole('list', { name: 'Chosen filters' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Clear all' })).toBeNull();
  });

  it('ticks choices in a labelled list, shows the count and a chip for each', () => {
    render(<Harness />);
    fireEvent.click(screen.getByRole('button', { name: 'Status' }));
    const list = screen.getByRole('dialog', { name: 'Status' });
    // A short list has no search box.
    expect(within(list).queryByRole('searchbox')).toBeNull();
    fireEvent.click(within(list).getByRole('checkbox', { name: 'Confirmed' }));
    fireEvent.click(within(list).getByRole('checkbox', { name: 'Paused' }));
    expect(value()).toEqual({ status: ['Confirmed', 'Paused'] });
    expect(screen.getByRole('button', { name: 'Status (2)' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove Confirmed' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove Paused' })).toBeInTheDocument();
  });

  it('a long list has a search box that narrows it', () => {
    render(<Harness />);
    fireEvent.click(screen.getByRole('button', { name: 'Cohort' }));
    const list = screen.getByRole('dialog', { name: 'Cohort' });
    expect(within(list).getAllByRole('checkbox')).toHaveLength(many.length);
    fireEvent.change(within(list).getByRole('searchbox', { name: 'Search cohort' }), {
      target: { value: 'cohort 1' },
    });
    // Cohort 1 and Cohort 10.
    expect(within(list).getAllByRole('checkbox')).toHaveLength(2);
    fireEvent.change(within(list).getByRole('searchbox', { name: 'Search cohort' }), {
      target: { value: 'nobody' },
    });
    expect(within(list).getByText('Nothing matches your search.')).toBeInTheDocument();
  });

  it('a chip removes its value, and Clear all removes every one', () => {
    render(<Harness start={{ cohort: ['Cohort 2', 'Cohort 3'], status: ['Paused'] }} />);
    const chips = screen.getByRole('list', { name: 'Chosen filters' });
    fireEvent.click(within(chips).getByRole('button', { name: 'Remove Cohort 2' }));
    expect(value()).toEqual({ cohort: ['Cohort 3'], status: ['Paused'] });
    fireEvent.click(screen.getByRole('button', { name: 'Clear all' }));
    expect(value()).toEqual({});
    expect(screen.queryByRole('list', { name: 'Chosen filters' })).toBeNull();
  });

  it('Clear in a list clears only that field', () => {
    render(<Harness start={{ cohort: ['Cohort 2'], status: ['Paused'] }} />);
    fireEvent.click(screen.getByRole('button', { name: 'Status (1)' }));
    const list = screen.getByRole('dialog', { name: 'Status' });
    fireEvent.click(within(list).getByRole('button', { name: 'Clear' }));
    expect(value()).toEqual({ cohort: ['Cohort 2'] });
  });
});
