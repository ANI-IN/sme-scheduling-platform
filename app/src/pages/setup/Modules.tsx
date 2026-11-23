import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { BookOpen, ChevronRight, Plus } from 'lucide-react';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useSettingsMap, useTeam } from '@/lib/data';
import { moduleStatusLabel } from '@/lib/labels';
import {
  Badge,
  Button,
  Checkbox,
  Empty,
  ErrorText,
  PageHeader,
  SkeletonRows,
  tableWrap,
  td,
  th,
  thead,
  trowClick,
} from '@/components/ui';
import type { ModuleRow } from './moduleParts';

/** Draft (being set up, nobody is asked), Live (instructors are asked) or Archived (glossary). */
export const MODULE_STATUS: Record<string, { label: string; tone: 'success' | 'neutral' }> = {
  Active: { label: moduleStatusLabel('Active'), tone: 'success' },
  Inactive: { label: moduleStatusLabel('Inactive'), tone: 'neutral' },
  Archived: { label: moduleStatusLabel('Archived'), tone: 'neutral' },
};

/** How many instructors in use a module needs in its instructor order to be Ready (a setting, 1 by default). */
export function useMinInstructors(domainId: string | undefined) {
  const settings = useSettingsMap(domainId);
  return Number(settings.data?.min_active_instructors ?? 1);
}

/**
 * Problems with a module's setup, in plain words. A module is Ready with class times, an owner and at least the
 * set number of instructors in use in its instructor order. The contact check is optional, so it is not one.
 */
export function useModuleWarnings(domainId: string | undefined) {
  const instructors = useInstructors();
  const minActive = useMinInstructors(domainId);
  const byId = new Map((instructors.data ?? []).map((i) => [i.id, i]));
  return (m: ModuleRow): string[] => {
    const ranked = m.module_ranking
      .filter((r) => !r.cohort_id)
      .map((r) => byId.get(r.instructor_id));
    const active = ranked.filter((i) => i?.status === 'Active').length;
    const w: string[] = [];
    if (!m.class_pattern_item.some((p) => !p.cohort_id)) w.push('No class times');
    if (active < minActive)
      w.push(`Needs ${minActive} instructor${minActive === 1 ? '' : 's'}, has ${active}`);
    if (m.module_owner.length === 0) w.push('No owner');
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

  const minActive = useMinInstructors(domain?.id);

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
      {domain && (
        <p className="mb-4 text-sm text-muted-foreground">
          A module is <strong>Draft</strong> while you set it up and nobody is asked. It is{' '}
          <strong>Live</strong> when instructors are asked. It is Ready with class times, an owner
          and at least {minActive} instructor{minActive === 1 ? '' : 's'} in its instructor order.
        </p>
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
