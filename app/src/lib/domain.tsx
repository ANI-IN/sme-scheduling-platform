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
    const domains = data ?? [];
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
