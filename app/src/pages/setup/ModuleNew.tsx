import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Check, CircleAlert, CircleCheck, UserPlus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useSettings, useTeam } from '@/lib/data';
import { useFormErrors } from '@/lib/useFormErrors';
import {
  Button,
  cn,
  ErrorText,
  Field,
  Input,
  Notice,
  PageHeader,
  Section,
  Select,
} from '@/components/ui';
import { InstructorDrawer } from '../Instructors';
import { PatternEditor, RankingEditor, Resources, WEEKDAYS, type ModuleRow } from './moduleParts';
import { Owners } from './ModuleDetail';

const STEPS = [
  'Module details',
  'Class times',
  'Instructor order',
  'Owners and operations team',
  'Materials',
  'Review and save',
];

/** Guided setup for a new module. The module is saved as "not in use" until the last step. */
export default function ModuleNew() {
  const { domain, domains } = useDomain();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [step, setStep] = useState(0);
  const [moduleId, setModuleId] = useState<string | null>(null);
  const [domainId, setDomainId] = useState(domain?.id ?? '');
  const modules = useModules(domainId || domain?.id);
  const m = modules.data?.find((x) => x.id === moduleId) ?? null;
  const [err, setErr] = useState<unknown>(null);

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

  return (
    <div>
      <PageHeader
        title="Add module"
        description="Set up a module step by step. You can come back to any step, and change everything later on the module page."
        breadcrumbs={[{ label: 'Modules', to: '/setup/modules' }, { label: 'Add module' }]}
      />
      <ol className="mb-6 grid gap-2 sm:grid-cols-3 lg:grid-cols-6" aria-label="Steps">
        {STEPS.map((label, i) => {
          const done = i < step;
          const reachable = i === 0 || !!m;
          return (
            <li key={label}>
              <button
                type="button"
                disabled={!reachable}
                onClick={() => setStep(i)}
                aria-current={i === step ? 'step' : undefined}
                className={cn(
                  'flex h-full w-full items-center gap-2 rounded-md border px-2.5 py-2 text-left text-sm leading-tight disabled:opacity-50',
                  i === step
                    ? 'border-primary bg-primary-soft text-foreground'
                    : 'border-border bg-card text-muted-foreground hover:bg-muted',
                )}
              >
                <span
                  className={cn(
                    'flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-xs font-semibold',
                    done
                      ? 'bg-primary text-primary-foreground'
                      : i === step
                        ? 'bg-primary text-primary-foreground'
                        : 'bg-muted text-muted-foreground',
                  )}
                >
                  {done ? <Check className="h-3 w-3" aria-hidden /> : i + 1}
                </span>
                <span>{label}</span>
              </button>
            </li>
          );
        })}
      </ol>
      <ErrorText error={err} />

      {step === 0 && (
        <DetailsStep
          module={m}
          domainId={domainId}
          setDomainId={setDomainId}
          domains={domains}
          nextOrder={(modules.data?.filter((x) => x.status !== 'Archived').length ?? 0) + 1}
          onSaved={(id) => {
            setModuleId(id);
            setStep(1);
          }}
        />
      )}
      {step > 0 && m && (
        <>
          {step === 1 && (
            <Section
              title="Class times"
              description="The classes of one class week, in Pacific time. The planner uses them to create classes."
            >
              <PatternEditor module={m} run={run} />
            </Section>
          )}
          {step === 2 && <OrderStep module={m} />}
          {step === 3 && <PeopleStep module={m} run={run} />}
          {step === 4 && (
            <Section
              title="Materials"
              description="Links sent to instructors with the confirmation and reminders, and shown when they ask for help."
            >
              <Resources module={m} run={run} />
            </Section>
          )}
          {step === 5 && <Review module={m} onFinish={(active) => finish(active)} />}
          {step < 5 && (
            <div className="mt-5 flex justify-between">
              <Button variant="secondary" onClick={() => setStep(step - 1)}>
                Back
              </Button>
              <Button onClick={() => setStep(step + 1)}>Continue</Button>
            </div>
          )}
        </>
      )}
    </div>
  );

  async function finish(active: boolean) {
    if (!m) return;
    if (active) {
      await run(
        async () =>
          check(
            await supabase
              .from('module')
              .update({ status: 'Active', version: m.version })
              .eq('id', m.id)
              .select(),
          ),
        'Module saved and in use',
      );
    } else {
      toast.success('Module saved as not in use');
    }
    navigate(`/setup/modules/${m.id}`);
  }
}

function DetailsStep({
  module: m,
  domainId,
  setDomainId,
  domains,
  nextOrder,
  onSaved,
}: {
  module: ModuleRow | null;
  domainId: string;
  setDomainId: (id: string) => void;
  domains: { id: string; name: string }[];
  nextOrder: number;
  onSaved: (id: string) => void;
}) {
  const qc = useQueryClient();
  const [name, setName] = useState(m?.name ?? '');
  const [order, setOrder] = useState<number | ''>(m?.rotation_order ?? '');
  const [err, setErr] = useState<unknown>(null);
  const [saving, setSaving] = useState(false);
  const v = useFormErrors({
    name: !name.trim() ? 'Enter a name, for example Concurrency.' : undefined,
    domain: !domainId ? 'Choose a domain.' : undefined,
  });
  return (
    <Section
      title="Module details"
      description="Saved as not in use until you finish, so it is not planned or used for requests yet."
    >
      <div className="grid max-w-2xl gap-4 sm:grid-cols-2">
        <Field label="Name" required error={v.show('name')}>
          <Input
            value={name}
            autoFocus
            onBlur={v.touch('name')}
            onChange={(e) => setName(e.target.value)}
          />
        </Field>
        <Field label="Domain" required error={v.show('domain')}>
          <Select
            value={domainId}
            disabled={!!m}
            onBlur={v.touch('domain')}
            onChange={(e) => setDomainId(e.target.value)}
          >
            <option value="">Choose a domain</option>
            {domains.map((d) => (
              <option key={d.id} value={d.id}>
                {d.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field
          label="Order in the rotation"
          hint={`1 is the first module. Leave empty to put it last (${nextOrder}).`}
        >
          <Input
            type="number"
            min={1}
            value={order}
            onChange={(e) => setOrder(e.target.value ? Number(e.target.value) : '')}
          />
        </Field>
      </div>
      <ErrorText error={err} />
      <div className="mt-5 flex justify-end">
        <Button
          loading={saving}
          onClick={async () => {
            if (!v.submit()) return;
            setErr(null);
            setSaving(true);
            try {
              if (m) {
                check(
                  await supabase
                    .from('module')
                    .update({
                      name: name.trim(),
                      rotation_order: order || m.rotation_order,
                      version: m.version,
                    })
                    .eq('id', m.id)
                    .select(),
                );
                await qc.invalidateQueries();
                onSaved(m.id);
              } else {
                const created = check(
                  await supabase
                    .from('module')
                    .insert({
                      domain_id: domainId,
                      name: name.trim(),
                      rotation_order: order || nextOrder,
                      status: 'Inactive',
                    })
                    .select()
                    .single(),
                )!;
                await qc.invalidateQueries();
                onSaved(created.id);
              }
            } catch (e) {
              setErr(e);
            } finally {
              setSaving(false);
            }
          }}
        >
          Save and continue
        </Button>
      </div>
    </Section>
  );
}

function OrderStep({ module: m }: { module: ModuleRow }) {
  const instructors = useInstructors();
  const [adding, setAdding] = useState(false);
  const [extra, setExtra] = useState<string[]>([]);
  return (
    <Section
      title="Instructor order"
      description="Who we ask first: the primary instructor, then Backup 1, Backup 2 and so on, one at a time. Choose existing instructors and drag them into order, then save."
    >
      <RankingEditor
        key={extra.join()}
        module={m}
        initialExtra={extra}
        footer={
          <Button variant="ghost" onClick={() => setAdding(true)}>
            <UserPlus className="h-4 w-4" aria-hidden /> Add new instructor
          </Button>
        }
      />
      {adding && (
        <InstructorDrawer
          instructor={null}
          all={instructors.data ?? []}
          onClose={() => setAdding(false)}
          onSaved={(id) => setExtra((x) => [...x, id])}
        />
      )}
    </Section>
  );
}

function PeopleStep({
  module: m,
  run,
}: {
  module: ModuleRow;
  run: (fn: () => Promise<unknown>, ok?: string) => Promise<void>;
}) {
  const team = useTeam();
  const ops = useQuery({
    queryKey: ['domain_team', m.domain_id],
    queryFn: async () =>
      check(
        await supabase
          .from('domain_team')
          .select('*')
          .eq('domain_id', m.domain_id)
          .eq('role', 'Ops'),
      ),
  });
  const names = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  return (
    <div className="space-y-4">
      <Owners module={m} run={run} />
      <Section
        title="Operations team"
        description="Shared by every module of the domain. They handle checklists, failed messages and written replies."
      >
        <p className="text-sm">
          {(ops.data ?? [])
            .map((r) => names.get(r.team_member_id))
            .filter(Boolean)
            .join(', ') || 'Nobody yet.'}{' '}
          <Link to="/setup/domains" className="text-link hover:underline">
            Change on the Domains page
          </Link>
        </p>
      </Section>
    </div>
  );
}

function Review({
  module: m,
  onFinish,
}: {
  module: ModuleRow;
  onFinish: (active: boolean) => void;
}) {
  const team = useTeam();
  const instructors = useInstructors();
  const settings = useSettings(m.domain_id);
  const names = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  const byId = new Map((instructors.data ?? []).map((i) => [i.id, i]));
  const order = [...m.module_ranking]
    .sort((a, b) => a.rank - b.rank)
    .map((r) => byId.get(r.instructor_id));
  const required = [
    { ok: m.class_pattern_item.length > 0, text: 'At least one class time' },
    {
      ok: order.some((i) => i?.status === 'Active'),
      text: 'At least one active instructor in the order',
    },
    { ok: m.module_owner.length > 0, text: 'At least one owner' },
  ];
  const ready = required.every((r) => r.ok);
  const setting = (k: string) => settings.data?.find((s) => s.key === k);
  const timing = ['readiness_days', 'outreach_days', 'checkin_days', 'window_long_move_h']
    .map(setting)
    .filter(Boolean);
  const row = (label: string, value: React.ReactNode) => (
    <div className="grid gap-1 border-b border-border py-2 last:border-0 sm:grid-cols-3">
      <dt className="text-sm text-muted-foreground">{label}</dt>
      <dd className="text-sm sm:col-span-2">{value}</dd>
    </div>
  );
  return (
    <div className="space-y-4">
      <Section title="Before you save">
        <ul className="space-y-1.5 text-sm">
          {required.map((r) => (
            <li
              key={r.text}
              className={cn(
                'flex items-center gap-2',
                r.ok ? 'text-success-strong' : 'text-danger-strong',
              )}
            >
              {r.ok ? (
                <CircleCheck className="h-4 w-4" aria-hidden />
              ) : (
                <CircleAlert className="h-4 w-4" aria-hidden />
              )}
              {r.text}
              {!r.ok && <span className="text-muted-foreground">(required)</span>}
            </li>
          ))}
          <li
            className={cn(
              'flex items-center gap-2',
              m.module_resource.length ? 'text-success-strong' : 'text-warning-strong',
            )}
          >
            {m.module_resource.length ? (
              <CircleCheck className="h-4 w-4" aria-hidden />
            ) : (
              <CircleAlert className="h-4 w-4" aria-hidden />
            )}
            Materials {m.module_resource.length ? '' : '(recommended)'}
          </li>
        </ul>
      </Section>
      <Section title="Summary">
        <dl>
          {row('Name', m.name)}
          {row('Order in the rotation', m.rotation_order)}
          {row(
            'Class times (Pacific)',
            m.class_pattern_item.length
              ? [...m.class_pattern_item]
                  .sort((a, b) => a.weekday_offset - b.weekday_offset)
                  .map(
                    (p) =>
                      `${p.class_type}, ${WEEKDAYS[p.weekday_offset % 7]} ${p.start_time_pt.slice(0, 5)}, ${p.duration_minutes} minutes`,
                  )
                  .join('; ')
              : 'None',
          )}
          {row(
            'Instructor order',
            order.length
              ? order
                  .map(
                    (i, idx) =>
                      `${idx === 0 ? 'Primary' : `Backup ${idx}`}: ${i?.full_name ?? 'Unknown'}`,
                  )
                  .join('; ')
              : 'None',
          )}
          {row(
            'Owners',
            m.module_owner.map((o) => names.get(o.team_member_id)).join(', ') || 'None',
          )}
          {row('Materials', m.module_resource.map((r) => r.title).join(', ') || 'None')}
        </dl>
      </Section>
      <Section
        title="Timing for this domain"
        description="Set once per domain for every module. Shown here so you know what will happen."
        actions={
          <Link to="/settings/automation" className="text-sm font-medium text-link hover:underline">
            Change in Automation
          </Link>
        }
      >
        <dl>
          {timing.map((s) =>
            row(
              s!.label,
              Array.isArray(s!.value) ? (s!.value as number[]).join(' and ') : String(s!.value),
            ),
          )}
        </dl>
      </Section>
      {!ready && (
        <Notice tone="warning">
          Finish the required items to start using this module. You can also save it now and finish
          later.
        </Notice>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={() => onFinish(false)}>
          Save as not in use
        </Button>
        <Button disabled={!ready} onClick={() => onFinish(true)}>
          Save and start using
        </Button>
      </div>
    </div>
  );
}
