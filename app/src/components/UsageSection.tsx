// Settings, Connections, Usage (Release 3, M13, decision 307): how close the app is to its free plan limits. Admins
// only; the numbers come from usage_summary. docs/FREE_TIER_LIMITS.md explains each limit.
import { useQuery } from '@tanstack/react-query';
import { rpc } from '@/lib/rpc';
import { Badge, ErrorText, Section, SkeletonRows } from '@/components/ui';

type Usage = {
  database_bytes: number;
  database_limit_bytes: number;
  messages: {
    today: number;
    month: number;
    email_today: number;
    email_month: number;
    discord_today: number;
    discord_month: number;
  };
  email_cap: number;
  email_cap_left: number;
  n8n_runs_month: number;
  n8n_limit_month: number;
  n8n_by_workflow: { workflow: string; runs: number; last_at: string | null }[];
  n8n_counted_since: string | null;
};

const mb = (b: number) => `${(b / 1024 / 1024).toFixed(1)} MB`;
const pct = (n: number, of: number) => (of > 0 ? Math.round((n / of) * 100) : 0);

function Meter({
  label,
  value,
  of,
  shown,
}: {
  label: string;
  value: number;
  of: number;
  shown: string;
}) {
  const p = pct(value, of);
  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
        <span className="font-medium">{label}</span>
        <span>
          {shown}{' '}
          <Badge tone={p >= 90 ? 'danger' : p >= 75 ? 'warning' : 'success'}>{p}% used</Badge>
        </span>
      </div>
      <div
        className="mt-1 h-2 overflow-hidden rounded bg-muted"
        role="meter"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={of}
        aria-valuenow={value}
      >
        <div
          className={
            p >= 90
              ? 'h-full bg-danger-strong'
              : p >= 75
                ? 'h-full bg-warning-strong'
                : 'h-full bg-success-strong'
          }
          style={{ width: `${Math.min(100, p)}%` }}
        />
      </div>
    </div>
  );
}

export function UsageSection() {
  const usage = useQuery({
    queryKey: ['usage'],
    queryFn: async () => (await rpc('usage_summary', {})) as unknown as Usage,
  });
  const u = usage.data;
  return (
    <Section
      title="Usage"
      description="How close the app is to the limits of its free plans. Only admins see this."
    >
      {usage.isLoading ? (
        <SkeletonRows rows={3} />
      ) : usage.error ? (
        <ErrorText error={usage.error} />
      ) : (
        u && (
          <div className="space-y-4">
            <Meter
              label="Database size"
              value={u.database_bytes}
              of={u.database_limit_bytes}
              shown={`${mb(u.database_bytes)} of ${mb(u.database_limit_bytes)}`}
            />
            <Meter
              label="Emails in the last 24 hours"
              value={u.email_cap - u.email_cap_left}
              of={u.email_cap}
              shown={`${u.email_cap_left} of ${u.email_cap} left`}
            />
            <Meter
              label="Automation service runs this month"
              value={u.n8n_runs_month}
              of={u.n8n_limit_month}
              shown={`${u.n8n_runs_month.toLocaleString()} of ${u.n8n_limit_month.toLocaleString()}`}
            />
            <p className="text-xs text-muted-foreground">
              Runs are counted by the app
              {u.n8n_counted_since ? ` since ${u.n8n_counted_since.slice(0, 7)}` : ''}. The
              plan&apos;s 10,000 a month are shared with the other projects in the same automation
              account, so the service&apos;s own count can be higher.
              {u.n8n_by_workflow.length > 0 &&
                ` By workflow: ${u.n8n_by_workflow.map((w) => `${w.workflow} ${w.runs}`).join(', ')}.`}
            </p>
            <dl className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-3">
              <div>
                <dt className="text-muted-foreground">Messages sent today</dt>
                <dd className="font-medium">
                  {u.messages.today} ({u.messages.email_today} email, {u.messages.discord_today}{' '}
                  Discord)
                </dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Messages sent this month</dt>
                <dd className="font-medium">
                  {u.messages.month} ({u.messages.email_month} email, {u.messages.discord_month}{' '}
                  Discord)
                </dd>
              </div>
            </dl>
          </div>
        )
      )}
    </Section>
  );
}
