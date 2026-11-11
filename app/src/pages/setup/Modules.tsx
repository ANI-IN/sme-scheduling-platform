import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { BookOpen, ChevronRight, Plus } from 'lucide-react';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useSettingsMap, useTeam } from '@/lib/data';
import {
  Badge,
  Button,
  Checkbox,
  Empty,
  ErrorText,
  Notice,
  PageHeader,
  SkeletonRows,
  tableWrap,
  td,
  th,
  thead,
  trowClick,
} from '@/components/ui';
import type { ModuleRow } from './moduleParts';

export const MODULE_STATUS: Record<string, { label: string; tone: 'success' | 'neutral' }> = {
  Active: { label: 'In use', tone: 'success' },
  Inactive: { label: 'Not in use', tone: 'neutral' },
  Archived: { label: 'Archived', tone: 'neutral' },
};

/** Problems with a module's setup, in plain words. Contact checks are summarised once per page instead. */
export function useModuleWarnings(domainId: string | undefined) {
  const instructors = useInstructors();
  const settings = useSettingsMap(domainId);
  const minActive = Number(settings.data?.min_active_instructors ?? 2);
  const byId = new Map((instructors.data ?? []).map((i) => [i.id, i]));
  return (m: ModuleRow): string[] => {
    const ranked = [...m.module_ranking]
      .filter((r) => !r.cohort_id)
      .sort((a, b) => a.rank - b.rank)
      .map((r) => byId.get(r.instructor_id));
    const active = ranked.filter((i) => i?.status === 'Active').length;
    const w: string[] = [];
    if (!m.class_pattern_item.some((p) => !p.cohort_id)) w.push('No class times');
    if (active < minActive) w.push(`Needs ${minActive} instructors, has ${active}`);
    if (ranked[0] && ranked[0].status !== 'Active') w.push('Primary instructor is not in use');
    if (m.module_owner.length === 0) w.push('No owner');
    if (m.module_resource.length === 0) w.push('No materials');
    return w;
  };
}

export default function Modules() {
  const { domain } = useDomain();
  const modules = useModules(domain?.id);
  const instructors = useInstructors();
  const team = useTeam();
  const navigate = useNavigate();
  const warnings = useModuleWarnings(domain?.id);
  const overview = useQuery({
    queryKey: ['module', 'overview', domain?.id],
    enabled: !!domain,
    queryFn: async () =>
      (await rpc('module_overview', { p_domain_id: domain!.id })) as unknown as Record<
        string,
        { owners: string; operations: string; operations_is_default: boolean; needed: number }
      >,
  });
  const owners = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  const status = new Map((instructors.data ?? []).map((i) => [i.id, i]));
  // Archived modules are listed only when asked for (decision 256).
  const [showArchived, setShowArchived] = useState(false);
  const archivedCount = (modules.data ?? []).filter((m) => m.status === 'Archived').length;
  const shown = (modules.data ?? []).filter((m) => showArchived || m.status !== 'Archived');

  // One summary instead of the same warning on every module.
  const ranked = new Set(
    (modules.data ?? []).flatMap((m) => m.module_ranking.map((r) => r.instructor_id)),
  );
  const unchecked = [...ranked].filter((id) => {
    const i = status.get(id);
    return i && i.status === 'Active' && !i.verified_at && !i.is_test;
  }).length;

  return (
    <div>
      <PageHeader
        title="Modules"
        description={
          domain
            ? `The modules of ${domain.name}, in the order they rotate.`
            : 'Choose a domain first.'
        }
      >
        {domain && (
          <Button onClick={() => navigate('/setup/modules/new')}>
            <Plus className="h-4 w-4" aria-hidden /> Add module
          </Button>
        )}
      </PageHeader>
      {unchecked > 0 && (
        <div className="mb-4">
          <Notice tone="warning">
            {unchecked} instructor{unchecked === 1 ? ' has' : 's have'} not had their contact
            details checked yet, so they will not be asked once the domain is live.{' '}
            <Link
              to="/setup/instructors?show=unchecked"
              className="font-medium underline underline-offset-2"
            >
              Review instructors
            </Link>
          </Notice>
        </div>
      )}
      <ErrorText error={modules.error} />
      {archivedCount > 0 && (
        <div className="mb-3">
          <Checkbox
            label={`Show archived modules (${archivedCount})`}
            checked={showArchived}
            onChange={setShowArchived}
          />
        </div>
      )}
      {!domain ? (
        <Empty title="No domain yet">Create a domain on the Domains page first.</Empty>
      ) : modules.isLoading ? (
        <SkeletonRows />
      ) : shown.length === 0 ? (
        <Empty
          title="No modules yet"
          icon={<BookOpen className="h-5 w-5" />}
          action={<Button onClick={() => navigate('/setup/modules/new')}>Add module</Button>}
        >
          Add the modules of {domain.name} in the order they rotate.
        </Empty>
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Order</th>
                <th className={th}>Module</th>
                <th className={th}>Status</th>
                <th className={th}>Owners</th>
                <th className={`${th} hidden lg:table-cell`}>Operations team</th>
                <th className={th}>Instructors</th>
                <th className={th}>Needs attention</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((m) => {
                const w = warnings(m);
                const active = m.module_ranking.filter(
                  (r) => !r.cohort_id && status.get(r.instructor_id)?.status === 'Active',
                ).length;
                return (
                  <tr
                    key={m.id}
                    className={trowClick}
                    onClick={() => navigate(`/setup/modules/${m.id}`)}
                  >
                    <td className={`${td} tabular-nums`}>{m.rotation_order}</td>
                    <td className={td}>
                      <Link
                        to={`/setup/modules/${m.id}`}
                        className="inline-flex items-center gap-1 font-medium text-link hover:underline"
                        onClick={(e) => e.stopPropagation()}
                      >
                        {m.name}
                        <ChevronRight className="h-4 w-4" aria-hidden />
                      </Link>
                    </td>
                    <td className={td}>
                      <Badge tone={MODULE_STATUS[m.status]?.tone}>
                        {MODULE_STATUS[m.status]?.label ?? m.status}
                      </Badge>
                    </td>
                    <td className={td}>
                      {m.module_owner.map((o) => owners.get(o.team_member_id)).join(', ') || (
                        <span className="text-muted-foreground">None yet</span>
                      )}
                    </td>
                    <td className={`${td} hidden lg:table-cell`}>
                      {overview.data?.[m.id]?.operations || (
                        <span className="text-muted-foreground">None yet</span>
                      )}
                      {overview.data?.[m.id]?.operations_is_default &&
                        overview.data?.[m.id]?.operations && (
                          <div className="text-xs text-muted-foreground">Domain default</div>
                        )}
                    </td>
                    <td className={`${td} tabular-nums`}>{active}</td>
                    <td className={td}>
                      <div className="flex flex-wrap gap-1">
                        {w.length === 0 ? (
                          <Badge tone="success">Ready</Badge>
                        ) : (
                          w.map((x) => (
                            <Badge key={x} tone="warning">
                              {x}
                            </Badge>
                          ))
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
