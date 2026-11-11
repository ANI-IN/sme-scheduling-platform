import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Globe2, Plus, X } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useCohorts, useDomains, useTeam, type Domain } from '@/lib/data';
import { RegionBadge } from '@/components/ClassTime';
import { isDiscordId } from '@/lib/validation';
import { useFormErrors } from '@/lib/useFormErrors';
import { useConfirm } from '@/components/Confirm';
import { PeoplePicker } from '@/components/PeoplePicker';
import { statusLabel, statusTone } from '@/components/AppShell';
import {
  Badge,
  Checkbox,
  DateInput,
  formatDateValue,
  Button,
  Drawer,
  Empty,
  ErrorText,
  Field,
  Input,
  Modal,
  PageHeader,
  Section,
  Select,
  SkeletonRows,
  tableWrap,
  td,
  th,
  thead,
  trowClick,
} from '@/components/ui';

const STATUS_HELP: Record<string, string> = {
  Draft: 'Being set up. Nothing is sent.',
  Test: 'Messages go only to the testing channel and testing email.',
  Live: 'Real instructors are asked and reminded.',
  Paused: 'No messages to instructors; requests wait until it is turned back on.',
};

export default function Domains() {
  const domains = useDomains();
  const team = useTeam();
  const roles = useQuery({
    queryKey: ['domain_team'],
    queryFn: async () => check(await supabase.from('domain_team').select('*')),
  });
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const names = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  const people = (d: string, role: string) =>
    (roles.data ?? [])
      .filter((r) => r.domain_id === d && r.role === role)
      .map((r) => names.get(r.team_member_id))
      .filter(Boolean)
      .join(', ');
  const current = (domains.data ?? []).find((d) => d.id === open);
  return (
    <div>
      <PageHeader
        title="Domains"
        description="Program areas such as Backend. Each domain has its own status, alert channel, escalation contacts and operations team."
      >
        <Button onClick={() => setCreating(true)}>
          <Plus className="h-4 w-4" aria-hidden /> Create domain
        </Button>
      </PageHeader>
      {domains.isLoading ? (
        <SkeletonRows rows={3} />
      ) : (domains.data ?? []).length === 0 ? (
        <Empty
          title="No domains yet"
          icon={<Globe2 className="h-5 w-5" />}
          action={<Button onClick={() => setCreating(true)}>Create domain</Button>}
        />
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Domain</th>
                <th className={th}>Status</th>
                <th className={th}>Escalation contacts</th>
                <th className={th}>Operations team</th>
                <th className={th}>Alert channel</th>
              </tr>
            </thead>
            <tbody>
              {(domains.data ?? []).map((d) => (
                <tr key={d.id} className={trowClick} onClick={() => setOpen(d.id)}>
                  <td className={`${td} font-medium`}>
                    <button
                      type="button"
                      className="text-left font-medium hover:underline"
                      onClick={(e) => {
                        e.stopPropagation();
                        setOpen(d.id);
                      }}
                    >
                      {d.name}
                    </button>
                  </td>
                  <td className={td}>
                    <Badge tone={statusTone[d.status]}>{statusLabel[d.status]}</Badge>
                  </td>
                  <td className={td}>
                    {people(d.id, 'Escalation') || (
                      <span className="text-muted-foreground">None yet</span>
                    )}
                  </td>
                  <td className={td}>
                    {people(d.id, 'Operations') || (
                      <span className="text-muted-foreground">None yet</span>
                    )}
                  </td>
                  <td className={td}>
                    {d.alert_discord_channel_id ? (
                      <Badge tone="success">Set</Badge>
                    ) : (
                      <Badge tone="warning">Missing</Badge>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {current && (
        <DomainDrawer
          key={`${current.id}:${current.version}`}
          domain={current}
          onClose={() => setOpen(null)}
        />
      )}
      {creating && (
        <CreateDomain
          onClose={() => setCreating(false)}
          onCreated={(id) => (setCreating(false), setOpen(id))}
        />
      )}
    </div>
  );
}

function CreateDomain({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: (id: string) => void;
}) {
  const qc = useQueryClient();
  const { setDomainId } = useDomain();
  const [name, setName] = useState('');
  const [copyFrom, setCopyFrom] = useState('');
  const domains = useDomains();
  const [err, setErr] = useState<unknown>(null);
  const v = useFormErrors({
    name: !name.trim() ? 'Enter a name, for example Fullstack.' : undefined,
  });
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Create domain"
      description="New domains start as Draft, so nothing is sent until you are ready."
    >
      <Field label="Domain name" required error={v.show('name')}>
        <Input
          value={name}
          autoFocus
          onBlur={v.touch('name')}
          onChange={(e) => setName(e.target.value)}
        />
      </Field>
      {(domains.data ?? []).length > 0 && (
        <Field
          label="Copy settings from another domain (optional)"
          hint="Copies the automation settings, class types and message texts. Modules and people are not copied."
          className="mt-3"
        >
          <Select value={copyFrom} onChange={(e) => setCopyFrom(e.target.value)}>
            <option value="">Start with the defaults</option>
            {(domains.data ?? []).map((d) => (
              <option key={d.id} value={d.id}>
                {d.name}
              </option>
            ))}
          </Select>
        </Field>
      )}
      <ErrorText error={err} />
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button
          onClick={async () => {
            if (!v.submit()) return;
            try {
              const d = check(
                await supabase
                  .from('domain')
                  .insert({ name: name.trim(), status: 'Draft' })
                  .select()
                  .single(),
              )!;
              if (copyFrom)
                await rpc('copy_domain_settings', {
                  p_from_domain_id: copyFrom,
                  p_to_domain_id: d.id,
                });
              setDomainId(d.id);
              toast.success('Domain created');
              await qc.invalidateQueries();
              onCreated(d.id);
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Create domain
        </Button>
      </div>
    </Modal>
  );
}

function DomainDrawer({ domain, onClose }: { domain: Domain; onClose: () => void }) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const team = useTeam();
  const roles = useQuery({
    queryKey: ['domain_team', domain.id],
    queryFn: async () =>
      check(await supabase.from('domain_team').select('*').eq('domain_id', domain.id)),
  });
  const [name, setName] = useState(domain.name);
  const [alert, setAlert] = useState(domain.alert_discord_channel_id ?? '');
  const [err, setErr] = useState<unknown>(null);
  const v = useFormErrors({
    name: !name.trim() ? 'Enter a name.' : undefined,
    alert: alert && !isDiscordId(alert) ? 'A channel ID is 17 to 20 digits.' : undefined,
  });
  const ids = (role: string) =>
    (roles.data ?? []).filter((r) => r.role === role).map((r) => r.team_member_id);

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setErr(null);
    try {
      await fn();
      if (ok) toast.success(ok);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  }

  async function setStatus(status: string) {
    if (status === domain.status) return;
    const leavingTest = domain.status === 'Test' && status !== 'Test';
    if (status === 'Live' || leavingTest) {
      const ok = await confirm({
        title: status === 'Live' ? `Go live with ${domain.name}?` : `Stop testing ${domain.name}?`,
        body:
          status === 'Live'
            ? 'Real instructors will be contacted from the next automatic check.'
            : `${domain.name} will be ${statusLabel[status]?.toLowerCase()}. Messages stop going to the testing channel.`,
        danger: status === 'Live',
        confirmLabel: status === 'Live' ? 'Go live' : `Set to ${statusLabel[status]}`,
      });
      if (!ok) return;
    }
    await run(
      () => rpc('set_domain_status', { p_domain_id: domain.id, p_status: status }),
      `Status: ${statusLabel[status]}`,
    );
  }

  const role = (r: 'Escalation' | 'Operations') => ({
    onAdd: (id: string) =>
      run(async () =>
        check(
          await supabase
            .from('domain_team')
            .insert({ domain_id: domain.id, team_member_id: id, role: r }),
        ),
      ),
    onRemove: (id: string) =>
      run(async () =>
        check(
          await supabase
            .from('domain_team')
            .delete()
            .eq('domain_id', domain.id)
            .eq('team_member_id', id)
            .eq('role', r),
        ),
      ),
  });

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={domain.name}
      description="Changes save as you make them, except the name and alert channel."
    >
      <div className="space-y-5">
        <Section title="Status" description={STATUS_HELP[domain.status]}>
          <Select
            value={domain.status}
            onChange={(e) => void setStatus(e.target.value)}
            className="w-56"
            aria-label="Status"
          >
            {['Draft', 'Test', 'Live', 'Paused'].map((s) => (
              <option key={s} value={s}>
                {statusLabel[s]}
              </option>
            ))}
          </Select>
          <ul className="mt-3 space-y-1 text-xs text-muted-foreground">
            {Object.entries(STATUS_HELP).map(([k, t]) => (
              <li key={k}>
                <span className="font-medium text-foreground">{statusLabel[k]}:</span> {t}
              </li>
            ))}
          </ul>
        </Section>
        <Section title="Details">
          <div className="space-y-4">
            <Field label="Name" required error={v.show('name')}>
              <Input
                value={name}
                onBlur={v.touch('name')}
                onChange={(e) => setName(e.target.value)}
              />
            </Field>
            <Field
              label="Alert channel ID"
              hint="The Discord channel where the team is tagged about this domain. Right click the channel, then Copy Channel ID."
              error={v.show('alert')}
            >
              <Input
                value={alert}
                onBlur={v.touch('alert')}
                onChange={(e) => setAlert(e.target.value)}
              />
            </Field>
            <Button
              variant="secondary"
              disabled={name === domain.name && alert === (domain.alert_discord_channel_id ?? '')}
              onClick={() =>
                v.submit() &&
                run(
                  async () =>
                    check(
                      await supabase
                        .from('domain')
                        .update({
                          name: name.trim(),
                          alert_discord_channel_id: alert || null,
                          version: domain.version,
                        })
                        .eq('id', domain.id)
                        .select(),
                    ),
                  'Changes saved',
                )
              }
            >
              Save changes
            </Button>
          </div>
        </Section>
        <Section
          title="Escalation contacts"
          description="Gets told when an urgent problem is not fixed in time."
        >
          <PeoplePicker
            people={team.data ?? []}
            selected={ids('Escalation')}
            addLabel="Add an escalation contact"
            {...role('Escalation')}
          />
        </Section>
        <Section
          title="Default operations team"
          description="Handle class tasks, failed messages and written replies for every module, unless a module has its own operations team."
        >
          <PeoplePicker
            people={team.data ?? []}
            selected={ids('Operations')}
            addLabel="Add a person"
            {...role('Operations')}
          />
        </Section>
        <Cohorts domainId={domain.id} />
        <ClassTypes domainId={domain.id} />
        <Holidays domainId={domain.id} domainName={domain.name} />
        <ErrorText error={err} />
      </div>
    </Drawer>
  );
}

/** The kinds of class this domain teaches (used when adding class times and single classes). */
function ClassTypes({ domainId }: { domainId: string }) {
  const qc = useQueryClient();
  const types = useQuery({
    queryKey: ['class_type', domainId],
    queryFn: async () =>
      check(
        await supabase
          .from('class_type')
          .select('*')
          .eq('domain_id', domainId)
          .order('sort_order')
          .order('name'),
      ),
  });
  const [name, setName] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['class_type'] });
  return (
    <Section
      title="Class types"
      description="For example Live class, Assignment review or Office hours. A class week can have any number of classes of any type."
    >
      <ul className="mb-3 flex flex-wrap gap-2">
        {(types.data ?? []).map((t) => (
          <li
            key={t.id}
            className="inline-flex items-center gap-1 rounded-full border border-border px-2.5 py-0.5 text-sm"
          >
            {t.name}
            <button
              type="button"
              aria-label={`Remove ${t.name}`}
              className="text-muted-foreground hover:text-danger-strong"
              onClick={async () => {
                setErr(null);
                try {
                  check(await supabase.from('class_type').delete().eq('id', t.id));
                  toast.success('Class type removed');
                  await refresh();
                } catch (e) {
                  setErr(e);
                }
              }}
            >
              <X className="h-3.5 w-3.5" aria-hidden />
            </button>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="New class type">
          <Input value={name} onChange={(e) => setName(e.target.value)} className="w-56" />
        </Field>
        <Button
          variant="secondary"
          disabled={!name.trim()}
          onClick={async () => {
            setErr(null);
            try {
              check(
                await supabase.from('class_type').insert({
                  domain_id: domainId,
                  name: name.trim(),
                  sort_order: (types.data?.length ?? 0) + 1,
                }),
              );
              setName('');
              toast.success('Class type added');
              await refresh();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}

/** Each cohort is taught in one region: US (US Pacific time) or India (India time). */
function Cohorts({ domainId }: { domainId: string }) {
  const qc = useQueryClient();
  const cohorts = useCohorts(domainId);
  const [err, setErr] = useState<unknown>(null);
  return (
    <Section
      title="Cohorts and regions"
      description="New classes of a cohort are planned in its time zone. Changing the region does not move classes already planned; change one class under More options in its details."
    >
      {(cohorts.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No cohorts yet. A cohort is created when you plan its classes.
        </p>
      ) : (
        <ul className="grid gap-1.5 text-sm sm:grid-cols-2">
          {(cohorts.data ?? []).map((c) => (
            <li
              key={c.id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border px-3 py-1.5"
            >
              <span className="flex items-center gap-2">
                <span className="font-medium">{c.name}</span>
                <RegionBadge region={c.region} />
              </span>
              <Select
                aria-label={`Region of ${c.name}`}
                value={c.region}
                className="h-8 w-48"
                onChange={async (e) => {
                  setErr(null);
                  try {
                    check(
                      await supabase
                        .from('cohort')
                        .update({ region: e.target.value, version: c.version })
                        .eq('id', c.id)
                        .select()
                        .single(),
                    );
                    toast.success(
                      `${c.name} is now planned in ${e.target.value === 'India' ? 'India time' : 'US Pacific time'}`,
                    );
                    await qc.invalidateQueries({ queryKey: ['cohort'] });
                  } catch (x) {
                    setErr(x);
                  }
                }}
              >
                <option value="US">US Pacific time</option>
                <option value="India">India time (IST)</option>
              </Select>
            </li>
          ))}
        </ul>
      )}
      <ErrorText error={err} />
    </Section>
  );
}

/** Holidays for this domain, plus those that apply to every domain. Shown when planning. */
function Holidays({ domainId, domainName }: { domainId: string; domainName: string }) {
  const qc = useQueryClient();
  const holidays = useQuery({
    queryKey: ['holiday', domainId],
    queryFn: async () =>
      check(
        await supabase
          .from('holiday')
          .select('*')
          .or(`domain_id.is.null,domain_id.eq.${domainId}`)
          .order('date'),
      ),
  });
  const [h, setH] = useState({ date: '', name: '', onlyHere: true, region: 'US' });
  const [touched, setTouched] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const errors = {
    date: !h.date ? 'Choose a date.' : undefined,
    name: !h.name.trim() ? 'Give the holiday a name.' : undefined,
  };
  const refresh = () => qc.invalidateQueries({ queryKey: ['holiday'] });
  return (
    <Section
      title="Holidays"
      description="Shown when planning classes, so classes on a holiday get a warning. A US holiday only affects US classes, an India holiday only India classes."
    >
      {(holidays.data ?? []).length === 0 ? (
        <p className="mb-3 text-sm text-muted-foreground">No holidays yet.</p>
      ) : (
        <ul className="mb-4 grid gap-1.5 text-sm sm:grid-cols-2">
          {(holidays.data ?? []).map((x) => (
            <li
              key={x.id}
              className="flex items-center justify-between gap-2 rounded-md border border-border px-3 py-1.5"
            >
              <span>
                <span className="font-medium">{x.name}</span>
                <span className="text-muted-foreground">, {formatDateValue(x.date)}</span>
                <span className="block text-xs text-muted-foreground">
                  {x.region ? `${x.region} classes` : 'US and India classes'},{' '}
                  {x.domain_id ? `only ${domainName}` : 'every domain'}
                </span>
              </span>
              <Button
                size="sm"
                variant="ghost"
                onClick={async () => {
                  setErr(null);
                  try {
                    check(await supabase.from('holiday').delete().eq('id', x.id));
                    toast.success('Holiday removed');
                    await refresh();
                  } catch (e) {
                    setErr(e);
                  }
                }}
              >
                Remove
              </Button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Date" error={touched ? errors.date : undefined}>
          <DateInput value={h.date} onChange={(date) => setH({ ...h, date })} className="w-56" />
        </Field>
        <Field label="Name" error={touched ? errors.name : undefined}>
          <Input
            value={h.name}
            onChange={(e) => setH({ ...h, name: e.target.value })}
            className="w-56"
          />
        </Field>
        <Field label="Region">
          <Select
            value={h.region}
            onChange={(e) => setH({ ...h, region: e.target.value })}
            className="w-44"
          >
            <option value="US">US</option>
            <option value="India">India</option>
            <option value="">US and India</option>
          </Select>
        </Field>
        <Checkbox
          label={`Only for ${domainName}`}
          checked={h.onlyHere}
          onChange={(v) => setH({ ...h, onlyHere: v })}
        />
        <Button
          variant="secondary"
          onClick={async () => {
            setTouched(true);
            if (errors.date || errors.name) return;
            setErr(null);
            try {
              check(
                await supabase.from('holiday').insert({
                  date: h.date,
                  name: h.name.trim(),
                  domain_id: h.onlyHere ? domainId : null,
                  region: h.region || null,
                }),
              );
              setH({ date: '', name: '', onlyHere: h.onlyHere, region: h.region });
              setTouched(false);
              toast.success('Holiday added');
              await refresh();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add holiday
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}
