// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { SaveState } from './SaveState';

afterEach(cleanup);

describe('SaveState (C15)', () => {
  it('says Saving, then Saved, politely for screen readers', () => {
    const { rerender, container } = render(<SaveState status={{ state: 'saving', error: null }} />);
    expect(screen.getByText('Saving')).toBeInTheDocument();
    expect(container.firstElementChild).toHaveAttribute('aria-live', 'polite');
    rerender(<SaveState status={{ state: 'saved', error: null }} />);
    expect(screen.getByText('Saved')).toBeInTheDocument();
  });

  it('says why it was not saved, in plain words', () => {
    render(<SaveState status={{ state: 'error', error: 'Enter a name.' }} />);
    expect(screen.getByText('Not saved: Enter a name.')).toBeInTheDocument();
  });

  it('says when edits are still waiting to be saved', () => {
    render(<SaveState status={{ state: 'saved', error: null }} waiting />);
    expect(screen.getByText('Not saved yet')).toBeInTheDocument();
    expect(screen.queryByText('Saved')).toBeNull();
  });
});
