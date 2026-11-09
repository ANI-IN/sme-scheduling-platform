import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import { Button, Modal } from './ui';

type Opts = { title: string; body?: ReactNode; confirmLabel?: string; danger?: boolean };
type Ctx = (o: Opts) => Promise<boolean>;

const ConfirmCtx = createContext<Ctx>(async () => false);

/** "Are you sure?" prompts (PRD 7.1). Usage: `if (await confirm({ title })) …` */
export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<(Opts & { resolve: (v: boolean) => void }) | null>(null);
  const confirm = useCallback<Ctx>(
    (o) => new Promise((resolve) => setState({ ...o, resolve })),
    [],
  );
  const close = (v: boolean) => {
    state?.resolve(v);
    setState(null);
  };
  return (
    <ConfirmCtx.Provider value={confirm}>
      {children}
      <Modal open={!!state} onOpenChange={(o) => !o && close(false)} title={state?.title ?? ''}>
        {state?.body && <div className="mb-4 text-sm text-slate-600">{state.body}</div>}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={() => close(false)}>
            Cancel
          </Button>
          <Button variant={state?.danger ? 'danger' : 'primary'} onClick={() => close(true)}>
            {state?.confirmLabel ?? 'Yes, continue'}
          </Button>
        </div>
      </Modal>
    </ConfirmCtx.Provider>
  );
}

export const useConfirm = () => useContext(ConfirmCtx);
