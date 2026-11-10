// The app's component kit (shadcn-style, Tailwind + Radix). Every color comes from the theme
// tokens in index.css, so each component works in light and dark themes.
import { Dialog as D, Tabs as T, Tooltip as Tip } from 'radix-ui';
import { AlertCircle, CalendarDays, ChevronRight, Info, Loader2, X } from 'lucide-react';
import { clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { Link } from 'react-router-dom';
import type {
  ButtonHTMLAttributes,
  InputHTMLAttributes,
  ReactNode,
  SelectHTMLAttributes,
  TextareaHTMLAttributes,
} from 'react';

export function cn(...c: (string | false | null | undefined)[]): string {
  return twMerge(clsx(c));
}

// ------------------------------------------------------------------------------------ buttons
type Variant = 'primary' | 'secondary' | 'ghost' | 'destructive' | 'outline' | 'danger' | 'link';
const variants: Record<Variant, string> = {
  primary: 'bg-primary text-primary-foreground hover:bg-primary-hover shadow-sm',
  secondary: 'border border-input bg-card text-foreground hover:bg-muted shadow-sm',
  outline: 'border border-input bg-card text-foreground hover:bg-muted shadow-sm',
  ghost: 'text-foreground hover:bg-muted',
  destructive: 'bg-destructive text-destructive-foreground hover:bg-destructive-hover shadow-sm',
  danger: 'bg-destructive text-destructive-foreground hover:bg-destructive-hover shadow-sm',
  link: 'text-link underline-offset-4 hover:underline px-0',
};

export function Button({
  variant = 'primary',
  size = 'md',
  loading,
  className,
  children,
  ...p
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  size?: 'sm' | 'md' | 'icon';
  loading?: boolean;
}) {
  return (
    <button
      type="button"
      {...p}
      disabled={p.disabled || loading}
      className={cn(
        'inline-flex shrink-0 items-center justify-center gap-1.5 rounded-md font-medium whitespace-nowrap transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring disabled:pointer-events-none disabled:opacity-50',
        size === 'sm' && 'h-8 px-2.5 text-sm',
        size === 'md' && 'h-9 px-3.5 text-sm',
        size === 'icon' && 'h-8 w-8',
        variants[variant],
        className,
      )}
    >
      {loading && <Loader2 className="h-4 w-4 animate-spin" aria-hidden />}
      {children}
    </button>
  );
}

// ------------------------------------------------------------------------------------ inputs
const field =
  'w-full rounded-md border border-input bg-card px-2.5 py-1.5 text-sm text-foreground placeholder:text-muted-foreground focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-ring disabled:cursor-not-allowed disabled:bg-muted aria-[invalid=true]:border-destructive';

export function Input({ className, ...p }: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...p} className={cn(field, 'h-9', className)} />;
}

/** "Wed, Nov 18, 2026" for a yyyy-mm-dd value (no time zone shift). */
export function formatDateValue(v: string): string {
  const [y, m, d] = v.split('-').map(Number);
  if (!y || !m || !d) return v;
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC',
  });
}

/**
 * A date picker that shows the date as "Wed, Nov 18, 2026" (any day of the week). The native picker
 * sits on top, invisible, so the calendar, keyboard entry and screen readers work as usual.
 */
export function DateInput({
  value,
  onChange,
  className,
  placeholder = 'Choose a date',
  ...p
}: Omit<InputHTMLAttributes<HTMLInputElement>, 'onChange' | 'value' | 'type'> & {
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className={cn('relative h-9 min-w-44', className)}>
      <input
        {...p}
        type="date"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onClick={(e) => {
          try {
            e.currentTarget.showPicker?.();
          } catch {
            /* older browsers open their own picker */
          }
        }}
        className="peer absolute inset-0 h-full w-full cursor-pointer opacity-0"
      />
      <div
        aria-hidden
        className={cn(
          field,
          'pointer-events-none flex h-9 items-center justify-between gap-2 peer-focus-visible:outline-2 peer-focus-visible:outline-ring',
          !value && 'text-muted-foreground',
        )}
      >
        <span className="truncate">{value ? formatDateValue(value) : placeholder}</span>
        <CalendarDays className="h-4 w-4 shrink-0 text-muted-foreground" />
      </div>
    </div>
  );
}

export function Textarea({ className, ...p }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea {...p} className={cn(field, 'min-h-20', className)} />;
}

export function Select({ className, children, ...p }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select {...p} className={cn(field, 'h-9 pr-8', className)}>
      {children}
    </select>
  );
}

export function Field({
  label,
  hint,
  error,
  required,
  children,
  className,
}: {
  label: ReactNode;
  hint?: ReactNode;
  error?: string;
  required?: boolean;
  children: ReactNode;
  className?: string;
}) {
  return (
    <label className={cn('block space-y-1', className)}>
      <span className="block text-sm font-medium text-foreground">
        {label}
        {required && <span className="ml-0.5 text-danger-strong">*</span>}
      </span>
      {children}
      {hint && !error && <span className="block text-xs text-muted-foreground">{hint}</span>}
      {error && (
        <span className="flex items-center gap-1 text-xs text-danger-strong" role="alert">
          <AlertCircle className="h-3.5 w-3.5" aria-hidden /> {error}
        </span>
      )}
    </label>
  );
}

export function Checkbox({
  label,
  checked,
  onChange,
  disabled,
  hint,
}: {
  label: ReactNode;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
  hint?: ReactNode;
}) {
  return (
    <label
      className={cn(
        'inline-flex items-start gap-2 text-sm text-foreground',
        disabled && 'opacity-60',
      )}
    >
      <input
        type="checkbox"
        className="mt-0.5 h-4 w-4 rounded border-input accent-[var(--primary)]"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span>
        {label}
        {hint && <span className="block text-xs text-muted-foreground">{hint}</span>}
      </span>
    </label>
  );
}

// ------------------------------------------------------------------------------------ badges
export type Tone =
  | 'neutral'
  | 'info'
  | 'success'
  | 'warning'
  | 'danger'
  | 'accent'
  | 'gray'
  | 'blue'
  | 'green'
  | 'amber'
  | 'red'
  | 'purple';
const tones: Record<Tone, string> = {
  neutral: 'bg-neutral-soft text-neutral-strong',
  info: 'bg-info-soft text-info-strong',
  success: 'bg-success-soft text-success-strong',
  warning: 'bg-warning-soft text-warning-strong',
  danger: 'bg-danger-soft text-danger-strong',
  accent: 'bg-accent-soft text-accent-strong',
  gray: 'bg-neutral-soft text-neutral-strong',
  blue: 'bg-info-soft text-info-strong',
  green: 'bg-success-soft text-success-strong',
  amber: 'bg-warning-soft text-warning-strong',
  red: 'bg-danger-soft text-danger-strong',
  purple: 'bg-accent-soft text-accent-strong',
};

export function Badge({
  tone = 'neutral',
  children,
  title,
  className,
}: {
  tone?: Tone;
  children: ReactNode;
  title?: string;
  className?: string;
}) {
  return (
    <span
      title={title}
      className={cn(
        'inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium whitespace-nowrap',
        tones[tone],
        className,
      )}
    >
      {children}
    </span>
  );
}

// ------------------------------------------------------------------------------------ surfaces
export function Card({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <div
      className={cn(
        'rounded-lg border border-border bg-card text-card-foreground shadow-sm',
        className,
      )}
    >
      {children}
    </div>
  );
}

/** A titled card section with an optional description and actions on the right. */
export function Section({
  title,
  description,
  actions,
  children,
  className,
  tone,
  id,
}: {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  children?: ReactNode;
  className?: string;
  tone?: 'danger';
  id?: string;
}) {
  return (
    <section
      id={id}
      className={cn(
        'rounded-lg border bg-card shadow-sm',
        tone === 'danger' ? 'border-destructive/40' : 'border-border',
        className,
      )}
    >
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-3">
        <div>
          <h2 className={cn('text-base font-semibold', tone === 'danger' && 'text-danger-strong')}>
            {title}
          </h2>
          {description && <p className="mt-0.5 text-sm text-muted-foreground">{description}</p>}
        </div>
        {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
      </header>
      {children && <div className="p-4">{children}</div>}
    </section>
  );
}

export function Empty({
  title,
  children,
  icon,
  action,
}: {
  title: string;
  children?: ReactNode;
  icon?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="rounded-lg border border-dashed border-border bg-card px-6 py-10 text-center">
      {icon && (
        <div className="mx-auto mb-2 flex h-10 w-10 items-center justify-center rounded-full bg-muted text-muted-foreground">
          {icon}
        </div>
      )}
      <p className="font-medium text-foreground">{title}</p>
      {children && (
        <div className="mx-auto mt-1 max-w-md text-sm text-muted-foreground">{children}</div>
      )}
      {action && <div className="mt-4 flex justify-center">{action}</div>}
    </div>
  );
}

export function ErrorText({ error }: { error: unknown }) {
  if (!error) return null;
  return (
    <div
      role="alert"
      className="flex items-start gap-2 rounded-md border border-destructive/30 bg-danger-soft px-3 py-2 text-sm text-danger-strong"
    >
      <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
      <span className="whitespace-pre-line">
        {error instanceof Error ? error.message : String(error)}
      </span>
    </div>
  );
}

export function Notice({
  tone = 'info',
  children,
  icon,
}: {
  tone?: 'info' | 'warning' | 'success' | 'danger';
  children: ReactNode;
  icon?: ReactNode;
}) {
  const cls = {
    info: 'border-info-strong/20 bg-info-soft text-info-strong',
    warning: 'border-warning-strong/25 bg-warning-soft text-warning-strong',
    success: 'border-success-strong/25 bg-success-soft text-success-strong',
    danger: 'border-destructive/30 bg-danger-soft text-danger-strong',
  }[tone];
  return (
    <div className={cn('flex items-start gap-2 rounded-md border px-3 py-2 text-sm', cls)}>
      <span className="mt-0.5 shrink-0">{icon ?? <Info className="h-4 w-4" aria-hidden />}</span>
      <div>{children}</div>
    </div>
  );
}

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" aria-label={label} />;
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={cn('animate-pulse rounded-md bg-muted', className)} aria-hidden />;
}

/** Placeholder rows while a list or table loads. */
export function SkeletonRows({ rows = 5 }: { rows?: number }) {
  return (
    <div
      className="space-y-2 rounded-lg border border-border bg-card p-4"
      role="status"
      aria-label="Loading"
    >
      {Array.from({ length: rows }, (_, i) => (
        <Skeleton key={i} className="h-8 w-full" />
      ))}
    </div>
  );
}

// ------------------------------------------------------------------------------------ overlays
export function Modal({
  open,
  onOpenChange,
  title,
  description,
  children,
  wide,
}: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  title: string;
  description?: string;
  children: ReactNode;
  wide?: boolean;
}) {
  return (
    <D.Root open={open} onOpenChange={onOpenChange}>
      <D.Portal>
        <D.Overlay className="fixed inset-0 z-40 bg-overlay" />
        <D.Content
          className={cn(
            'fixed top-1/2 left-1/2 z-50 max-h-[90vh] w-[calc(100vw-2rem)] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-xl border border-border bg-card p-5 text-card-foreground shadow-lg',
            wide ? 'max-w-5xl' : 'max-w-lg',
          )}
        >
          <div className="mb-4 flex items-start justify-between gap-4">
            <div>
              <D.Title className="text-lg font-semibold">{title}</D.Title>
              {description ? (
                <D.Description className="mt-0.5 text-sm text-muted-foreground">
                  {description}
                </D.Description>
              ) : (
                <D.Description className="sr-only">{title}</D.Description>
              )}
            </div>
            <D.Close
              className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
              aria-label="Close"
            >
              <X className="h-4 w-4" />
            </D.Close>
          </div>
          {children}
        </D.Content>
      </D.Portal>
    </D.Root>
  );
}

export function Drawer({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
}: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  title: string;
  description?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
}) {
  return (
    <D.Root open={open} onOpenChange={onOpenChange}>
      <D.Portal>
        <D.Overlay className="fixed inset-0 z-40 bg-overlay" />
        <D.Content className="fixed top-0 right-0 z-50 flex h-full w-full max-w-2xl flex-col border-l border-border bg-card text-card-foreground shadow-lg">
          <div className="flex items-start justify-between gap-4 border-b border-border px-5 py-4">
            <div>
              <D.Title className="text-lg font-semibold">{title}</D.Title>
              {description ? (
                <D.Description className="mt-0.5 text-sm text-muted-foreground">
                  {description}
                </D.Description>
              ) : (
                <D.Description className="sr-only">{title}</D.Description>
              )}
            </div>
            <D.Close
              className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
              aria-label="Close"
            >
              <X className="h-4 w-4" />
            </D.Close>
          </div>
          <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
          {footer && <div className="border-t border-border px-5 py-3">{footer}</div>}
        </D.Content>
      </D.Portal>
    </D.Root>
  );
}

export function HelpTip({
  children,
  label = 'More information',
}: {
  children: ReactNode;
  label?: string;
}) {
  return (
    <Tip.Provider delayDuration={150}>
      <Tip.Root>
        <Tip.Trigger asChild>
          <button
            type="button"
            className="inline-flex align-middle text-muted-foreground hover:text-foreground"
            aria-label={label}
          >
            <Info className="h-3.5 w-3.5" />
          </button>
        </Tip.Trigger>
        <Tip.Portal>
          <Tip.Content
            sideOffset={6}
            className="z-50 max-w-xs rounded-md border border-border bg-card px-2.5 py-1.5 text-xs text-card-foreground shadow-md"
          >
            {children}
          </Tip.Content>
        </Tip.Portal>
      </Tip.Root>
    </Tip.Provider>
  );
}

// ------------------------------------------------------------------------------------ tabs
export function Tabs({
  value,
  onValueChange,
  tabs,
  children,
}: {
  value: string;
  onValueChange: (v: string) => void;
  tabs: { value: string; label: ReactNode; badge?: ReactNode }[];
  children: ReactNode;
}) {
  return (
    <T.Root value={value} onValueChange={onValueChange}>
      <T.List className="mb-4 flex flex-wrap gap-1 border-b border-border" aria-label="Sections">
        {tabs.map((t) => (
          <T.Trigger
            key={t.value}
            value={t.value}
            className="-mb-px inline-flex items-center gap-1.5 border-b-2 border-transparent px-3 py-2 text-sm font-medium whitespace-nowrap text-muted-foreground hover:text-foreground data-[state=active]:border-primary data-[state=active]:text-foreground"
          >
            {t.label}
            {t.badge}
          </T.Trigger>
        ))}
      </T.List>
      {children}
    </T.Root>
  );
}
export const TabPanel = T.Content;

// ------------------------------------------------------------------------------------ page
export type Crumb = { label: string; to?: string };

export function Breadcrumbs({ items }: { items: Crumb[] }) {
  return (
    <nav
      aria-label="Breadcrumb"
      className="mb-1 flex items-center gap-1 text-sm text-muted-foreground"
    >
      {items.map((c, i) => (
        <span key={i} className="inline-flex items-center gap-1">
          {i > 0 && <ChevronRight className="h-3.5 w-3.5" aria-hidden />}
          {c.to ? (
            <Link to={c.to} className="hover:text-foreground hover:underline">
              {c.label}
            </Link>
          ) : (
            <span aria-current="page" className="text-foreground">
              {c.label}
            </span>
          )}
        </span>
      ))}
    </nav>
  );
}

export function PageHeader({
  title,
  description,
  breadcrumbs,
  children,
}: {
  title: string;
  description?: ReactNode;
  breadcrumbs?: Crumb[];
  children?: ReactNode;
}) {
  return (
    <div className="mb-5">
      {breadcrumbs && <Breadcrumbs items={breadcrumbs} />}
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h1 className="text-xl font-semibold tracking-tight text-foreground">{title}</h1>
          {description && <p className="mt-0.5 text-sm text-muted-foreground">{description}</p>}
        </div>
        {children && <div className="flex flex-wrap items-center gap-2">{children}</div>}
      </div>
    </div>
  );
}

/** A filter/search row above a list. */
export function Toolbar({ children }: { children: ReactNode }) {
  return <div className="mb-3 flex flex-wrap items-center gap-2">{children}</div>;
}

/** Summary card: a count with a label and optional hint. */
export function Stat({
  label,
  value,
  tone = 'neutral',
  hint,
  to,
  onClick,
  active,
}: {
  label: string;
  value: number | string;
  tone?: Tone;
  hint?: ReactNode;
  /** Makes the card a link to the matching list. */
  to?: string;
  /** Makes the card a filter button. */
  onClick?: () => void;
  /** Shown as selected (when the card is a filter). */
  active?: boolean;
}) {
  const dot = {
    neutral: 'bg-neutral-strong',
    gray: 'bg-neutral-strong',
    info: 'bg-info-strong',
    blue: 'bg-info-strong',
    success: 'bg-success-strong',
    green: 'bg-success-strong',
    warning: 'bg-warning-strong',
    amber: 'bg-warning-strong',
    danger: 'bg-danger-strong',
    red: 'bg-danger-strong',
    accent: 'bg-accent-strong',
    purple: 'bg-accent-strong',
  }[tone];
  const body = (
    <>
      <div className="flex items-center gap-2 text-sm text-muted-foreground">
        <span className={cn('h-2 w-2 rounded-full', dot)} aria-hidden />
        {label}
      </div>
      <div className="mt-1 text-2xl font-semibold text-foreground tabular-nums">{value}</div>
      {hint && <div className="mt-0.5 text-xs text-muted-foreground">{hint}</div>}
    </>
  );
  const cls = cn(
    'block min-w-36 flex-1 rounded-lg border bg-card px-4 py-3 text-left shadow-sm',
    active ? 'border-primary ring-1 ring-primary' : 'border-border',
    (to || onClick) && 'cursor-pointer transition-colors hover:border-primary/60 hover:bg-muted/40',
  );
  if (to)
    return (
      <Link to={to} className={cls}>
        {body}
      </Link>
    );
  if (onClick)
    return (
      <button type="button" className={cls} onClick={onClick} aria-pressed={!!active}>
        {body}
      </button>
    );
  return <div className={cls}>{body}</div>;
}

export const tableWrap = 'overflow-x-auto rounded-lg border border-border bg-card shadow-sm';
export const thead = 'border-b border-border bg-muted/60';
export const th =
  'px-3 py-2 text-left text-xs font-semibold tracking-wide text-muted-foreground uppercase';
export const td = 'px-3 py-2.5 align-top text-sm';
export const trow = 'border-b border-border last:border-0';
export const trowClick = 'border-b border-border last:border-0 cursor-pointer hover:bg-muted/60';
