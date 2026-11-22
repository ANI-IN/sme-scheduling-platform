import type { ReactNode } from 'react';

// A titled group inside a drawer (the class week drawer and its parts).
export function DrawerGroup({
  title,
  description,
  tone,
  children,
}: {
  title: string;
  description?: string;
  tone?: 'danger';
  children: ReactNode;
}) {
  return (
    <section className="space-y-3 border-t border-border pt-4">
      <div>
        <h3 className={tone === 'danger' ? 'font-semibold text-danger-strong' : 'font-semibold'}>
          {title}
        </h3>
        {description && <p className="text-xs text-muted-foreground">{description}</p>}
      </div>
      {children}
    </section>
  );
}
