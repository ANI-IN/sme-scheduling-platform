import { DropdownMenu as DM } from 'radix-ui';
import { MoreHorizontal } from 'lucide-react';
import { cn } from './ui';

export type MenuAction = {
  label: string;
  onSelect: () => void;
  danger?: boolean;
  disabled?: boolean;
  hidden?: boolean;
};

/** A "More options" menu for a row: keeps tables tidy while every action stays one click away. */
export function ActionMenu({
  label = 'More options',
  items,
}: {
  label?: string;
  items: MenuAction[];
}) {
  const shown = items.filter((i) => !i.hidden);
  if (shown.length === 0) return null;
  return (
    <DM.Root modal={false}>
      <DM.Trigger
        aria-label={label}
        title={label}
        className="inline-flex h-8 items-center gap-1 rounded-md border border-input bg-card px-2 text-sm text-foreground shadow-sm hover:bg-muted"
      >
        <MoreHorizontal className="h-4 w-4" aria-hidden />
        <span className="hidden sm:inline">More</span>
      </DM.Trigger>
      <DM.Portal>
        <DM.Content
          align="end"
          sideOffset={4}
          className="z-50 min-w-56 rounded-md border border-border bg-card p-1 text-card-foreground shadow-md"
        >
          {shown.map((i) => (
            <DM.Item
              key={i.label}
              disabled={i.disabled}
              onSelect={i.onSelect}
              className={cn(
                'cursor-pointer rounded px-2 py-1.5 text-sm outline-none data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50 data-[highlighted]:bg-muted',
                i.danger && 'text-danger-strong',
              )}
            >
              {i.label}
            </DM.Item>
          ))}
        </DM.Content>
      </DM.Portal>
    </DM.Root>
  );
}
