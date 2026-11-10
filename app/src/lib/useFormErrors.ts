import { useState } from 'react';

/**
 * Show a field's error only after the person has left that field or pressed Save, never while
 * the form is still empty.
 */
export function useFormErrors(errors: Record<string, string | undefined>) {
  const [touched, setTouched] = useState<Record<string, boolean>>({});
  const [submitted, setSubmitted] = useState(false);
  const hasErrors = Object.values(errors).some(Boolean);
  return {
    /** The error to show for a field right now (or undefined). */
    show: (field: string) => (touched[field] || submitted ? errors[field] : undefined),
    /** onBlur handler for a field. */
    touch: (field: string) => () => setTouched((t) => (t[field] ? t : { ...t, [field]: true })),
    /** Call on Save: shows every error; returns true when the form can be saved. */
    submit: () => {
      setSubmitted(true);
      return !hasErrors;
    },
    /** Forget touched fields after a successful save of a form that stays open. */
    reset: () => {
      setTouched({});
      setSubmitted(false);
    },
    hasErrors,
  };
}
