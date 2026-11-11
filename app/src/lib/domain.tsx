import { DateTime } from 'luxon';
import { createContext, useContext, useMemo, useState, type ReactNode } from 'react';
import { useDomains, type Domain } from './data';

type DomainCtx = { domain: Domain | null; domains: Domain[]; setDomainId: (id: string) => void };
const Ctx = createContext<DomainCtx>({ domain: null, domains: [], setDomainId: () => {} });

const KEY = 'ik-domain';
function readSaved(): string | null {
  try {
    return localStorage.getItem(KEY);
  } catch {
    return null;
  }
}

export function DomainProvider({ children }: { children: ReactNode }) {
  const { data } = useDomains();
  const [id, setId] = useState<string | null>(readSaved);
  const value = useMemo<DomainCtx>(() => {
    // Archived domains are not in the domain menu (Setup, Domains still lists them).
    const domains = (data ?? []).filter((d) => !d.archived_at);
    const domain = domains.find((d) => d.id === id) ?? domains[0] ?? null;
    return {
      domain,
      domains,
      setDomainId: (next) => {
        setId(next);
        try {
          localStorage.setItem(KEY, next);
        } catch {
          // per-viewer convenience only
        }
      },
    };
  }, [data, id]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export const useDomain = () => useContext(Ctx);

/** "Now" for the selected domain: its test clock in test mode, otherwise real time. */
export function useDomainNow(): DateTime {
  const { domain } = useDomain();
  return (domain?.status === 'Test' || domain?.paused_from === 'Test') && domain?.test_clock_at
    ? DateTime.fromISO(domain.test_clock_at)
    : DateTime.now();
}
