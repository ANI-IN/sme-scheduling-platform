// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { needsReason, WarningsDialog } from './WarningsDialog';

afterEach(cleanup);

describe('needsReason (decision 297)', () => {
  it('asks for a reason for a Warning, and also when the level is not given', () => {
    expect(needsReason([{ code: 'tight_gap', text: 'x', level: 'Warning' }])).toBe(true);
    expect(needsReason([{ code: 'holiday', text: 'x' }])).toBe(true);
  });
  it('does not ask for a reason for Information alone', () => {
    expect(needsReason([{ code: 'short_notice', text: 'x', level: 'Information' }])).toBe(false);
    expect(needsReason([])).toBe(false);
  });
});

describe('WarningsDialog', () => {
  it('lists the warnings and goes ahead only with a reason', () => {
    const onConfirm = vi.fn();
    render(
      <WarningsDialog
        warnings={[
          {
            code: 'tight_gap',
            text: 'Asha has only 15 minutes between two classes.',
            level: 'Warning',
          },
        ]}
        title="Assign anyway?"
        confirmLabel="Assign anyway"
        onCancel={() => {}}
        onConfirm={onConfirm}
      />,
    );
    expect(screen.getByText('Asha has only 15 minutes between two classes.')).toBeTruthy();
    const go = screen.getByRole('button', { name: 'Assign anyway' });
    expect((go as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '  They asked for it  ' } });
    expect((go as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(go);
    expect(onConfirm).toHaveBeenCalledWith('They asked for it');
  });

  it('lets Information through without a reason', () => {
    const onConfirm = vi.fn();
    render(
      <WarningsDialog
        warnings={[
          { code: 'short_notice', text: 'The class is only 3 days away.', level: 'Information' },
        ]}
        title="Add this class anyway?"
        confirmLabel="Add anyway"
        onCancel={() => {}}
        onConfirm={onConfirm}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: 'Add anyway' }));
    expect(onConfirm).toHaveBeenCalledWith('');
  });
});
