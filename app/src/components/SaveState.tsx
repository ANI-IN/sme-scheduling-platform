// The small mark next to a form that saves by itself (Release 3, C15): "Saving", "Saved", or why it was not saved,
// in plain words. Screen readers hear it too, politely, without moving the focus.
import { AlertCircle, Check, Loader2 } from 'lucide-react';
import type { SaveStatus } from '@/lib/autosave';
import { cn } from './ui';

export function SaveState({
  status,
  waiting,
  className,
}: {
  status: SaveStatus;
  /** There are edits that are not saved yet (still being typed, or a field has a problem). */
  waiting?: boolean;
  className?: string;
}) {
  const { state, error } = status;
  return (
    <span
      aria-live="polite"
      data-save-state={state}
      className={cn(
        'inline-flex min-h-5 items-start gap-1 text-xs',
        state === 'error' ? 'text-danger-strong' : 'text-muted-foreground',
        className,
      )}
    >
      {state === 'saving' ? (
        <>
          <Loader2 className="mt-px h-3.5 w-3.5 animate-spin" aria-hidden /> Saving
        </>
      ) : state === 'error' ? (
        <>
          <AlertCircle className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden />
          <span>Not saved: {error}</span>
        </>
      ) : waiting ? (
        'Not saved yet'
      ) : state === 'saved' ? (
        <>
          <Check className="mt-px h-3.5 w-3.5" aria-hidden /> Saved
        </>
      ) : null}
    </span>
  );
}
