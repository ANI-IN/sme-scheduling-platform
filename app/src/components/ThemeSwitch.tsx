import { Monitor, Moon, Sun } from 'lucide-react';
import { useTheme, type ThemeChoice } from '@/lib/theme';
import { cn } from './ui';

const options: { value: ThemeChoice; label: string; icon: typeof Sun }[] = [
  { value: 'light', label: 'Light', icon: Sun },
  { value: 'dark', label: 'Dark', icon: Moon },
  { value: 'system', label: 'System', icon: Monitor },
];

/** Light, Dark or System; switches instantly and is remembered. */
export function ThemeSwitch({ className }: { className?: string }) {
  const { choice, setChoice } = useTheme();
  return (
    <div
      role="radiogroup"
      aria-label="Theme"
      className={cn('inline-flex rounded-md border border-border bg-muted p-0.5', className)}
    >
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={choice === o.value}
          title={o.label}
          onClick={() => setChoice(o.value)}
          className={cn(
            'inline-flex h-7 items-center gap-1 rounded px-2 text-xs font-medium',
            choice === o.value
              ? 'bg-card text-foreground shadow-sm'
              : 'text-muted-foreground hover:text-foreground',
          )}
        >
          <o.icon className="h-3.5 w-3.5" aria-hidden />
          <span>{o.label}</span>
        </button>
      ))}
    </div>
  );
}
