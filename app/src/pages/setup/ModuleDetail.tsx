import { useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useCohorts, useModules, useTeam } from '@/lib/data';
import { LastChanged } from '@/components/LastChanged';
import { useFormErrors } from '@/lib/useFormErrors';
import { PeoplePicker } from '@/components/PeoplePicker';
import { ArchiveButton, DeleteButton, useRemovePart } from '@/components/Lifecycle';
import {
  Badge,
  Button,
  Checkbox,
  Empty,
  ErrorText,
  Field,
  Input,
  PageHeader,
  Section,
  Select,
  SkeletonRows,
  TabPanel,
  Tabs,
} from '@/components/ui';
import { PatternEditor, RankingEditor, WhoIsNext, type ModuleRow } from './moduleParts';
import { MODULE_STATUS, useModuleWarnings } from './Modules';

export const MODULE_TABS = [
  { value: 'details', label: 'Details' },
  { value: 'times', label: 'Class times' },
  { value: 'order', label: 'Instructor order' },
  { value: 'owners', label: 'Owners' },
  { value: 'operations', label: 'Operations team' },
  { value: 'next', label: 'Who we ask next' },
];

export default function ModuleDetail() {
  const { id } = useParams();
  const { domain } = useDomain();
  const modules = useModules(domain?.id);
  const m = modules.data?.find((x) => x.id === id);
  const warnings = useModuleWarnings(domain?.id);
  const [params, setParams] = useSearchParams();
  const tab = params.get('tab') ?? 'details';
  const [err, setErr] = useState<unknown>(null);
  const qc = useQueryClient();

  if (modules.isLoading) return <SkeletonRows rows={6} />;
  if (!m)
    return (
      <>
        <PageHeader
          title="Module"
          breadcrumbs={[{ label: 'Modules', to: '/setup/modules' }, { label: 'Not found' }]}
        />
        <Empty title="This module was not found">
          It may belong to another domain. Choose the domain in the sidebar.
        </Empty>
      </>
    );

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

  const w = warnings(m);
  return (
    <div>
      <PageHeader
        title={m.name}
        breadcrumbs={[{ label: 'Modules', to: '/setup/modules' }, { label: m.name }]}
        description={`Order ${m.rotation_order} in the ${domain?.name} rotation.`}
      >
        <Badge tone={MODULE_STATUS[m.status]?.tone}>{MODULE_STATUS[m.status]?.label}</Badge>
      </PageHeader>
      {w.length > 0 && (
        <div className="mb-4 flex flex-wrap items-center gap-1.5 text-sm">
          <span className="text-muted-foreground">Needs attention:</span>
          {w.map((x) => (
            <Badge key={x} tone="warning">
              {x}
            </Badge>
          ))}
        </div>
      )}
      <ErrorText error={err} />
      <Tabs
        value={tab}
        onValueChange={(v) => setParams({ tab: v }, { replace: true })}
        tabs={MODULE_TABS}
      >
        <TabPanel value="details">
          <DetailsForm key={m.version} module={m} run={run} />
        </TabPanel>
        <TabPanel value="times">
          <Section
            title="Class times"
            description="The classes of one class week, in the local time of each cohort (US Pacific or India). Used when planning classes."
          >
            <ForCohort module={m}>
              {(cohortId, hasOwn) =>
                cohortId && !hasOwn.times ? (
                  <>
                    <p className="mb-3 text-sm text-muted-foreground">
                      This cohort uses the module's class times. Add class times here to give it its
                      own, for example a weekday cohort.
                    </p>
                    <PatternEditor key={cohortId} module={m} run={run} cohortId={cohortId} />
                  </>
                ) : (
                  <PatternEditor
                    key={cohortId ?? 'module'}
                    module={m}
                    run={run}
                    cohortId={cohortId}
                  />
                )
              }
            </ForCohort>
          </Section>
        </TabPanel>
        <TabPanel value="order">
          <Section
            title="Instructor order"
            description="Who we ask first. The primary instructor is asked first, then Backup 1, Backup 2 and so on, one at a time."
          >
            <ForCohort module={m}>
              {(cohortId, hasOwn) => (
                <>
                  {cohortId && !hasOwn.order && (
                    <p className="mb-3 text-sm text-muted-foreground">
                      This cohort uses the module's instructor order. Save an order here to give it
                      its own.
                    </p>
                  )}
                  <RankingEditor key={cohortId ?? 'module'} module={m} cohortId={cohortId} />
                </>
              )}
            </ForCohort>
          </Section>
        </TabPanel>
        <TabPanel value="owners">
          <Owners module={m} run={run} />
        </TabPanel>
        <TabPanel value="operations">
          <OperationsTeam module={m} run={run} />
        </TabPanel>
        <TabPanel value="next">
          <Section
            title="Who we ask next"
            description="For each upcoming class week that has no instructor yet. This uses the same rules as the automation."
          >
            <WhoIsNext moduleId={m.id} />
          </Section>
        </TabPanel>
      </Tabs>
    </div>
  );
}

type Run = (fn: () => Promise<unknown>, ok?: string) => Promise<void>;

function DetailsForm({ module: m, run }: { module: ModuleRow; run: Run }) {
  const navigate = useNavigate();
  const [f, setF] = useState({
    name: m.name,
    rotation_order: m.rotation_order,
    status: m.status,
    same: m.same_instructor_for_module_week,
  });
  const v = useFormErrors({
    name: !f.name.trim() ? 'Enter a name.' : undefined,
    rotation_order: !(f.rotation_order >= 1) ? 'Use 1 or more.' : undefined,
  });
  const dirty =
    f.name !== m.name ||
    f.rotation_order !== m.rotation_order ||
    f.status !== m.status ||
    f.same !== m.same_instructor_for_module_week;
  return (
    <div className="space-y-5">
      <Section title="Module details">
        <div className="grid max-w-2xl gap-4 sm:grid-cols-2">
          <Field label="Name" required error={v.show('name')}>
            <Input
              value={f.name}
              onBlur={v.touch('name')}
              onChange={(e) => setF({ ...f, name: e.target.value })}
            />
          </Field>
          <Field
            label="Order in the rotation"
            hint="1 is the first module of the rotation."
            error={v.show('rotation_order')}
          >
            <Input
              type="number"
              min={1}
              value={f.rotation_order}
              onBlur={v.touch('rotation_order')}
              onChange={(e) => setF({ ...f, rotation_order: Number(e.target.value) })}
            />
          </Field>
          <Field
            label="Status"
            hint="Modules that are not in use are skipped when planning and asking."
          >
            <Select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
              {['Active', 'Inactive'].map((s) => (
                <option key={s} value={s}>
                  {MODULE_STATUS[s]?.label}
                </option>
              ))}
              {m.status === 'Archived' && <option value="Archived">Archived</option>}
            </Select>
          </Field>
          <div className="sm:col-span-2">
            <Checkbox
              label="The same instructor teaches the whole class week"
              hint="The live class and its review are booked together."
              checked={f.same}
              onChange={(c) => setF({ ...f, same: c })}
            />
          </div>
        </div>
        <Button
          className="mt-4"
          disabled={!dirty}
          onClick={() =>
            v.submit() &&
            run(
              async () =>
                check(
                  await supabase
                    .from('module')
                    .update({
                      name: f.name.trim(),
                      rotation_order: f.rotation_order,
                      status: f.status,
                      same_instructor_for_module_week: f.same,
                      version: m.version,
                    })
                    .eq('id', m.id)
                    .select(),
                ),
              'Changes saved',
            )
          }
        >
          Save changes
        </Button>
        <div className="mt-2">
          <LastChanged at={m.updated_at} by={m.updated_by} />
        </div>
      </Section>
      <Section
        title={m.status === 'Archived' ? 'Archived' : 'Archive or delete'}
        description={
          m.status === 'Archived'
            ? 'This module is archived: it is not planned, and its class weeks are paused. Restore it to use it again.'
            : 'Archive stops using the module and pauses its class weeks; you can restore it. Delete removes it, its class times and its class weeks for good.'
        }
      >
        <div className="flex flex-wrap gap-2">
          <ArchiveButton kind="module" id={m.id} name={m.name} archived={m.status === 'Archived'} />
          <DeleteButton kind="module" id={m.id} onDeleted={() => navigate('/setup/modules')} />
        </div>
      </Section>
    </div>
  );
}

export function Owners({ module: m, run }: { module: ModuleRow; run: Run }) {
  const team = useTeam();
  const qc = useQueryClient();
  const removePart = useRemovePart();
  const who = (id: string) => (team.data ?? []).find((t) => t.id === id)?.name ?? 'this person';
  return (
    <Section
      title="Owners"
      description="Owners are tagged when requests start, when an instructor confirms, and when something needs their decision."
    >
      <PeoplePicker
        people={team.data ?? []}
        selected={m.module_owner.map((o) => o.team_member_id)}
        addLabel="Add an owner"
        emptyText="No owner yet. A module needs at least one owner before requests can start."
        onAdd={(id) =>
          run(
            async () =>
              check(
                await supabase.from('module_owner').insert({ module_id: m.id, team_member_id: id }),
              ),
            'Owner added',
          )
        }
        onRemove={async (id) => {
          if (
            await removePart(
              `${who(id)} as an owner`,
              async () =>
                check(
                  await supabase
                    .from('module_owner')
                    .delete()
                    .eq('module_id', m.id)
                    .eq('team_member_id', id),
                ),
              'Owner removed',
            )
          )
            await qc.invalidateQueries();
        }}
      />
    </Section>
  );
}

/** Choose "the whole module" or one cohort for class times and the instructor order. */
function ForCohort({
  module: m,
  children,
}: {
  module: ModuleRow;
  children: (
    cohortId: string | undefined,
    hasOwn: { times: boolean; order: boolean },
  ) => React.ReactNode;
}) {
  const cohorts = useCohorts(m.domain_id);
  const [cohortId, setCohortId] = useState('');
  const own = (id: string) => ({
    times: m.class_pattern_item.some((p) => p.cohort_id === id),
    order: m.module_ranking.some((r) => r.cohort_id === id),
  });
  return (
    <div className="space-y-3">
      {(cohorts.data ?? []).length > 0 && (
        <Field label="For" className="max-w-sm">
          <Select value={cohortId} onChange={(e) => setCohortId(e.target.value)}>
            <option value="">Every cohort (the module default)</option>
            {(cohorts.data ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
                {own(c.id).times || own(c.id).order ? ' (has its own)' : ''}
              </option>
            ))}
          </Select>
        </Field>
      )}
      {children(cohortId || undefined, cohortId ? own(cohortId) : { times: true, order: true })}
    </div>
  );
}

/** Operations team for the module, and for a cohort when it differs. Empty means the domain default. */
function OperationsTeam({ module: m, run }: { module: ModuleRow; run: Run }) {
  const team = useTeam();
  const qc = useQueryClient();
  const removePart = useRemovePart();
  const cohorts = useCohorts(m.domain_id);
  const rows = useQuery({
    queryKey: ['module_operations', m.id],
    queryFn: async () =>
      check(await supabase.from('module_operations').select('*').eq('module_id', m.id)),
  });
  const defaults = useQuery({
    queryKey: ['domain_team', m.domain_id, 'Operations'],
    queryFn: async () =>
      check(
        await supabase
          .from('domain_team')
          .select('team_member_id')
          .eq('domain_id', m.domain_id)
          .eq('role', 'Operations'),
      ),
  });
  const names = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  const picker = (cohortId: string | null) => (
    <PeoplePicker
      people={(team.data ?? []).filter((t) => !t.access_removed_at)}
      selected={(rows.data ?? [])
        .filter((r) => r.cohort_id === cohortId)
        .map((r) => r.team_member_id)}
      addLabel="Add a person"
      emptyText={
        cohortId
          ? 'Same as the module.'
          : `Uses the domain's default operations team: ${
              (defaults.data ?? []).map((d) => names.get(d.team_member_id)).join(', ') ||
              'nobody yet'
            }.`
      }
      onAdd={(id) =>
        run(
          async () =>
            check(
              await supabase
                .from('module_operations')
                .insert({ module_id: m.id, cohort_id: cohortId, team_member_id: id }),
            ),
          'Added to the operations team',
        )
      }
      onRemove={async (id) => {
        if (
          await removePart(
            `${names.get(id) ?? 'this person'} from the operations team`,
            async () => {
              let q = supabase
                .from('module_operations')
                .delete()
                .eq('module_id', m.id)
                .eq('team_member_id', id);
              q = cohortId ? q.eq('cohort_id', cohortId) : q.is('cohort_id', null);
              check(await q);
            },
            'Removed from the operations team',
          )
        )
          await qc.invalidateQueries();
      }}
    />
  );
  return (
    <div className="space-y-4">
      <Section
        title="Operations team for this module"
        description="They handle class tasks, failed messages and written replies for this module. Leave it empty to use the domain's default operations team."
      >
        {picker(null)}
      </Section>
      {(cohorts.data ?? []).length > 0 && (
        <Section
          title="Different people for a cohort"
          description="Only when a cohort has its own operations team for this module."
        >
          <div className="space-y-4">
            {(cohorts.data ?? []).map((c) => (
              <div key={c.id}>
                <div className="mb-1 text-sm font-medium">{c.name}</div>
                {picker(c.id)}
              </div>
            ))}
          </div>
        </Section>
      )}
    </div>
  );
}
