// @vitest-environment jsdom
// No double submissions (owner, 24 November 2026): a button waits while what its click started is still running.
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Button } from './ui';

afterEach(cleanup);

describe('Button', () => {
  it('waits while its click is running, so a second click does nothing', async () => {
    let finish: () => void = () => {};
    const onClick = vi.fn(() => new Promise<void>((r) => (finish = r)));
    render(<Button onClick={onClick}>Save</Button>);
    const b = screen.getByRole('button', { name: 'Save' });
    fireEvent.click(b);
    expect(b).toBeDisabled();
    fireEvent.click(b);
    expect(onClick).toHaveBeenCalledTimes(1);
    await act(async () => finish());
    expect(b).not.toBeDisabled();
  });

  it('is pressable again after a failure', async () => {
    let fail: (e: Error) => void = () => {};
    render(<Button onClick={() => new Promise<void>((_, rej) => (fail = rej))}>Send</Button>);
    const b = screen.getByRole('button', { name: 'Send' });
    fireEvent.click(b);
    expect(b).toBeDisabled();
    await act(async () => fail(new Error('no')));
    expect(b).not.toBeDisabled();
  });

  it('a plain click handler never disables it', () => {
    const onClick = vi.fn();
    render(<Button onClick={onClick}>Open</Button>);
    const b = screen.getByRole('button', { name: 'Open' });
    fireEvent.click(b);
    fireEvent.click(b);
    expect(onClick).toHaveBeenCalledTimes(2);
    expect(b).not.toBeDisabled();
  });
});
