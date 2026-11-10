import { useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useModules, useTeam } from '@/lib/data';
import { useFormErrors } from '@/lib/useFormErrors';
import { useConfirm } from '@/components/Confirm';
import { PeoplePicker } from '@/components/PeoplePicker';
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
import { PatternEditor, RankingEditor, Resources, WhoIsNext, type ModuleRow } from './moduleParts';
import { MODULE_STATUS, useModuleWarnings } from './Modules';

export const MODULE_TABS = [
  { value: 'details', label: 'Details' },
  { value: 'times', label: 'Class times' },
  { value: 'order', label: 'Instructor order' },
  { value: 'owners', label: 'Owners' },
  { value: 'materials', label: 'Materials' },
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
            description="The classes of one class week, in Pacific time. Used when planning classes."
          >
            <PatternEditor module={m} run={run} />
          </Section>
        </TabPanel>
        <TabPanel value="order">
          <Section
            title="Instructor order"
            description="Who we ask first. The primary instructor is asked first, then Backup 1, Backup 2 and so on, one at a time."
          >
            <RankingEditor module={m} />
          </Section>
        </TabPanel>
        <TabPanel value="owners">
          <Owners module={m} run={run} />
        </TabPanel>
        <TabPanel value="materials">
          <Section
            title="Materials"
            description="Links sent to instructors in the confirmation and reminders, and shown when they ask for help."
          >
            <Resources module={m} run={run} />
          </Section>
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
  const confirm = useConfirm();
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
      </Section>
      {m.status !== 'Archived' && (
        <Section
          tone="danger"
          title="Archive this module"
          description="Modules with past classes are archived, never deleted. It stops being used for new plans and requests."
        >
          <Button
            variant="destructive"
            onClick={async () => {
              if (
                await confirm({
                  title: `Archive ${m.name}?`,
                  body: 'It will no longer be planned or used for instructor requests. Its history stays.',
                  danger: true,
                  confirmLabel: 'Archive module',
                })
              ) {
                await run(
                  async () =>
                    check(
                      await supabase
                        .from('module')
                        .update({ status: 'Archived', version: m.version })
                        .eq('id', m.id)
                        .select(),
                    ),
                  'Module archived',
                );
                navigate('/setup/modules');
              }
            }}
          >
            Archive module
          </Button>
        </Section>
      )}
    </div>
  );
}

export function Owners({ module: m, run }: { module: ModuleRow; run: Run }) {
  const team = useTeam();
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
        onRemove={(id) =>
          run(
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
        }
      />
    </Section>
  );
}
