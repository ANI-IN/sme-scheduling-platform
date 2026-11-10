import { DateTime } from 'luxon';
import { useTeam } from '@/lib/data';

/** "Last changed by Priya, 5 minutes ago": helps when several people manage the same thing. */
export function LastChanged({
  at,
  by,
}: {
  at: string | null | undefined;
  by: string | null | undefined;
}) {
  const team = useTeam();
  if (!at) return null;
  const who = by ? team.data?.find((t) => t.id === by)?.name : undefined;
  return (
    <p
      className="text-xs text-muted-foreground"
      title={DateTime.fromISO(at).toLocaleString(DateTime.DATETIME_MED)}
    >
      Last changed{who ? ` by ${who}` : ''}, {DateTime.fromISO(at).toRelative() ?? 'just now'}.
    </p>
  );
}
