import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

export type ThemeChoice = 'light' | 'dark' | 'system';
const KEY = 'ik-theme';

function read(): ThemeChoice {
  try {
    const v = localStorage.getItem(KEY);
    return v === 'light' || v === 'dark' ? v : 'system';
  } catch {
    return 'system';
  }
}

const systemDark = () => window.matchMedia('(prefers-color-scheme: dark)').matches;

function apply(choice: ThemeChoice) {
  const dark = choice === 'dark' || (choice === 'system' && systemDark());
  document.documentElement.classList.toggle('dark', dark);
}

type Ctx = { choice: ThemeChoice; resolved: 'light' | 'dark'; setChoice: (c: ThemeChoice) => void };
const ThemeCtx = createContext<Ctx>({ choice: 'system', resolved: 'light', setChoice: () => {} });

/** Light, Dark or System; remembered across sessions, applied instantly (index.html sets it before paint). */
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [choice, setChoiceState] = useState<ThemeChoice>(read);
  const [sysDark, setSysDark] = useState(systemDark);

  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const on = () => setSysDark(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, []);

  useEffect(() => apply(choice), [choice, sysDark]);

  const setChoice = (c: ThemeChoice) => {
    setChoiceState(c);
    try {
      if (c === 'system') localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, c);
    } catch {
      // the choice still applies for this visit
    }
  };
  const resolved = choice === 'dark' || (choice === 'system' && sysDark) ? 'dark' : 'light';
  return <ThemeCtx.Provider value={{ choice, resolved, setChoice }}>{children}</ThemeCtx.Provider>;
}

export const useTheme = () => useContext(ThemeCtx);
