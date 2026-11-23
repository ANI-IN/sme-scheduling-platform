// @vitest-environment jsdom
// Release 3, C15: small edits save by themselves, text after a pause, toggles at once.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { useAutosave } from './autosave';

type Form = { name: string; on: boolean };
type Props = { value: Form; stored: Form; version: number };

function setup(save: (v: Form, version: number | undefined) => Promise<number | void>) {
  const onReload = vi.fn();
  const start: Props = {
    value: { name: 'A', on: false },
    stored: { name: 'A', on: false },
    version: 1,
  };
  const hook = renderHook((p: Props) => useAutosave({ ...p, save, onReload, instant: ['on'] }), {
    initialProps: start,
  });
  return { ...hook, onReload };
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('useAutosave', () => {
  it('saves text after a pause, with the row version, and then says Saved', async () => {
    const save = vi.fn().mockResolvedValue(2);
    const { result, rerender } = setup(save);
    rerender({ value: { name: 'AB', on: false }, stored: { name: 'A', on: false }, version: 1 });
    expect(result.current.dirty).toBe(true);
    await act(() => vi.advanceTimersByTimeAsync(500));
    expect(save).not.toHaveBeenCalled();
    await act(() => vi.advanceTimersByTimeAsync(400));
    expect(save).toHaveBeenCalledWith({ name: 'AB', on: false }, 1);
    expect(result.current.status.state).toBe('saved');
    expect(result.current.version).toBe(2);
    expect(result.current.dirty).toBe(false);
  });

  it('saves a toggle at once', async () => {
    const save = vi.fn().mockResolvedValue(2);
    const { rerender } = setup(save);
    rerender({ value: { name: 'A', on: true }, stored: { name: 'A', on: false }, version: 1 });
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(save).toHaveBeenCalledWith({ name: 'A', on: true }, 1);
  });

  it('shows a change made somewhere else while there are no unsaved edits', () => {
    const { rerender, onReload, result } = setup(vi.fn());
    rerender({ value: { name: 'A', on: false }, stored: { name: 'B', on: false }, version: 2 });
    expect(onReload).toHaveBeenCalledWith({ name: 'B', on: false });
    expect(result.current.version).toBe(2);
  });

  it('keeps unsaved edits and the version they are based on', () => {
    const { rerender, onReload, result } = setup(vi.fn().mockReturnValue(new Promise(() => {})));
    rerender({ value: { name: 'Mine', on: false }, stored: { name: 'A', on: false }, version: 1 });
    rerender({ value: { name: 'Mine', on: false }, stored: { name: 'B', on: false }, version: 2 });
    expect(onReload).not.toHaveBeenCalled();
    expect(result.current.version).toBe(1);
  });

  it('says why a save was refused and does not try the same value again', async () => {
    const save = vi
      .fn()
      .mockRejectedValue(new Error('Someone else saved this after you opened it.'));
    const { result, rerender } = setup(save);
    rerender({ value: { name: 'X', on: false }, stored: { name: 'A', on: false }, version: 1 });
    await act(() => vi.advanceTimersByTimeAsync(900));
    expect(result.current.status).toEqual({
      state: 'error',
      error: 'Someone else saved this after you opened it.',
    });
    await act(() => vi.advanceTimersByTimeAsync(5000));
    expect(save).toHaveBeenCalledTimes(1);
  });
});
