import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Globe2, Plus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useDomains, useTeam, type Domain } from '@/lib/data';
import { isDiscordId } from '@/lib/validation';
import { useFormErrors } from '@/lib/useFormErrors';
import { useConfirm } from '@/components/Confirm';
import { PeoplePicker } from '@/components/PeoplePicker';
import { statusLabel, statusTone } from '@/components/AppShell';
import {
  Badge,
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
                  <td className={`${td} font-medium`}>{d.name}</td>
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
          title="Operations team"
          description="Handle tasks such as checklists, failed messages and written replies."
        >
          <PeoplePicker
            people={team.data ?? []}
            selected={ids('Operations')}
            addLabel="Add a person"
            {...role('Operations')}
          />
        </Section>
        <ErrorText error={err} />
      </div>
    </Drawer>
  );
}
