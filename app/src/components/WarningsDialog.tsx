import { useState } from 'react';
import { plain } from '@/lib/plain';
import { Button, Field, Input, Modal } from '@/components/ui';

/** One check result from the database (decision 297): a Block is refused there, so only these two reach here. */
export type CheckWarning = { code: string; text: string; level?: 'Warning' | 'Information' };

/** Going ahead despite a Warning needs a reason, kept in Activity history; Information alone does not. */
export function needsReason(warnings: readonly CheckWarning[]): boolean {
  return warnings.some((w) => (w.level ?? 'Warning') === 'Warning');
}

/**
 * The one "go ahead anyway?" dialog for every save that the database answers with warnings: adding, planning and
 * moving classes, and assigning an instructor. It lists the warnings in plain words and asks for the reason.
 */
export function WarningsDialog({
  warnings,
  title,
  confirmLabel,
  busy,
  onCancel,
  onConfirm,
}: {
  warnings: readonly CheckWarning[] | null;
  title: string;
  confirmLabel: string;
  busy?: boolean;
  onCancel: () => void;
  onConfirm: (reason: string) => void;
}) {
  const [reason, setReason] = useState('');
  // A new set of warnings starts with an empty reason.
  const [shown, setShown] = useState(warnings);
  if (warnings !== shown) {
    setShown(warnings);
    setReason('');
  }
  const required = needsReason(warnings ?? []);
  const missing = required && reason.trim() === '';
  return (
    <Modal
      open={!!warnings}
      onOpenChange={(o) => !o && onCancel()}
      title={title}
      description={
        required
          ? 'This is unusual but allowed. Say why you are going ahead: your reason is saved in Activity history.'
          : 'Please check this before you go ahead.'
      }
    >
      <ul className="mb-3 list-disc space-y-1 pl-5 text-sm">
        {(warnings ?? []).map((x, i) => (
          <li key={i}>{plain(x.text)}</li>
        ))}
      </ul>
      <Field
        label={required ? 'Reason' : 'Reason (optional)'}
        hint={required ? 'Needed to go ahead. Saved in Activity history.' : undefined}
      >
        <Input
          value={reason}
          aria-required={required}
          onChange={(e) => setReason(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !missing) onConfirm(reason.trim());
          }}
        />
      </Field>
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="secondary" onClick={onCancel}>
          Go back
        </Button>
        <Button loading={busy} disabled={missing} onClick={() => onConfirm(reason.trim())}>
          {confirmLabel}
        </Button>
      </div>
    </Modal>
  );
}
