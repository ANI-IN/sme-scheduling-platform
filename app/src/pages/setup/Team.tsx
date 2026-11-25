import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { BellRing, Plus, Users } from 'lucide-react';
import { useAuth } from '@/lib/auth';
import { useConfirm } from '@/components/Confirm';
import { DeleteButton } from '@/components/Lifecycle';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { refresh } from '@/lib/live';
import { useAutosave } from '@/lib/autosave';
import { SaveState } from '@/components/SaveState';
import { useBetaLock, useMe, useTeam, type TeamMember } from '@/lib/data';
import { BETA_LOCK_NOTE } from '@/lib/betaLock';
import { isEmail } from '@/lib/validation';
import { cleanUsername, usernameProblem } from '@/lib/discord';
import { DiscordStatus } from '@/components/Discord';
import { useFormErrors } from '@/lib/useFormErrors';
import {
  Badge,
  Button,
  Checkbox,
  Drawer,
  Empty,
  ErrorText,
  Field,
  Input,
  PageHeader,
  Select,
  SkeletonRows,
  tableWrap,
  td,
  th,
  thead,
  trowClick,
} from '@/components/ui';

const DIGEST_LABEL: Record<string, string> = {
  Discord: 'Discord',
  Email: 'Email',
  Both: 'Discord and email',
};

export default function Team() {
  const { data, isLoading, error } = useTeam();
  const [editing, setEditing] = useState<TeamMember | 'new' | null>(null);
  const assignments = useQuery({
    queryKey: ['team_member', 'assignments'],
    queryFn: async () => (await rpc('team_assignments', {})) as unknown as Record<string, string[]>,
  });
  return (
    <div>
      <PageHeader
        title="Team"
        description="Everyone who uses SME Scheduling. Add people here, or they appear after they sign in for the first time with their company Google account (only people an admin allows on Settings, Admin can sign in). Module owners, the operations team and escalation contacts are chosen from this list."
      >
        <Button onClick={() => setEditing('new')}>
          <Plus className="h-4 w-4" aria-hidden /> Add team member
        </Button>
      </PageHeader>
      <ErrorText error={error} />
      {isLoading ? (
        <SkeletonRows />
      ) : (data ?? []).length === 0 ? (
        <Empty
          title="No team members yet"
          icon={<Users className="h-5 w-5" />}
          action={<Button onClick={() => setEditing('new')}>Add team member</Button>}
        >
          Add them here, or ask your colleagues to sign in once with their company Google account.
          During the beta, an admin adds them to the beta list first.
        </Empty>
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Name</th>
                <th className={th}>Job title</th>
                <th className={`${th} hidden lg:table-cell`}>Helps with</th>
                <th className={th}>Email</th>
                <th className={th}>Discord</th>
                <th className={th}>Daily summary</th>
                <th className={th}>Access</th>
              </tr>
            </thead>
            <tbody>
              {(data ?? []).map((t) => (
                <tr key={t.id} className={trowClick} onClick={() => setEditing(t)}>
                  <td className={td}>
                    <button
                      type="button"
                      className="text-left font-medium hover:underline"
                      onClick={(e) => {
                        e.stopPropagation();
                        setEditing(t);
                      }}
                    >
                      {t.name}
                    </button>{' '}
                    {t.is_placeholder && <Badge tone="warning">Needs real details</Badge>}
                    {!t.active && <Badge>Not in use</Badge>}
                  </td>
                  <td className={td}>
                    {t.job_title || <span className="text-muted-foreground">Not set</span>}
                  </td>
                  <td className={`${td} hidden max-w-xs lg:table-cell`}>
                    {(assignments.data?.[t.id] ?? []).length ? (
                      <span className="text-sm">{assignments.data![t.id]!.join(', ')}</span>
                    ) : (
                      <span className="text-muted-foreground">Not assigned yet</span>
                    )}
                  </td>
                  <td className={`${td} text-muted-foreground`}>{t.email}</td>
                  <td className={td}>
                    {t.discord_user_id || t.discord_username ? (
                      <DiscordStatus
                        status={t.discord_status}
                        problem={t.discord_problem}
                        compact
                      />
                    ) : (
                      <span className="text-sm text-muted-foreground">Email only</span>
                    )}
                  </td>
                  <td className={td}>
                    {t.receives_digest ? DIGEST_LABEL[t.digest_channel] : 'Off'}
                  </td>
                  <td className={td}>
                    {t.access_removed_at ? (
                      <Badge tone="danger">Removed</Badge>
                    ) : (
                      <Badge tone="success">Has access</Badge>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {editing && (
        <MemberDrawer
          member={
            editing === 'new' ? null : ((data ?? []).find((x) => x.id === editing.id) ?? editing)
          }
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function MemberDrawer({ member, onClose }: { member: TeamMember | null; onClose: () => void }) {
  const isAdmin = !!useMe()?.is_admin;
  const locked = useBetaLock();
  const qc = useQueryClient();
  const [f, setF] = useState({
    name: member?.name ?? '',
    email: member?.email ?? '',
    discord_username: member?.discord_username ?? '',
    job_title: member?.job_title ?? '',
    receives_digest: member?.receives_digest ?? true,
    digest_channel: member?.digest_channel ?? 'Discord',
    active: member?.active ?? true,
  });
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const v = useFormErrors({
    name: !f.name.trim() ? 'Enter a name.' : undefined,
    email: !isEmail(f.email) ? 'Enter a valid email address.' : undefined,
    discord_username: usernameProblem(f.discord_username),
  });

  // Name, job title, the daily summary and In use save as they change (C15).
  const pickBasic = (x: typeof f) => ({
    name: x.name.trim(),
    job_title: x.job_title.trim(),
    receives_digest: x.receives_digest,
    digest_channel: x.digest_channel,
    active: x.active,
  });
  const auto = useAutosave({
    enabled: !!member,
    value: pickBasic(f),
    stored: pickBasic({
      ...f,
      name: member?.name ?? '',
      job_title: member?.job_title ?? '',
      receives_digest: member?.receives_digest ?? true,
      digest_channel: member?.digest_channel ?? 'Discord',
      active: member?.active ?? true,
    }),
    version: member?.version,
    instant: ['receives_digest', 'digest_channel', 'active'],
    valid: !!f.name.trim(),
    onReload: (x) => setF((cur) => ({ ...cur, ...x })),
    save: async (x, version) => {
      const [row] = check(
        await supabase
          .from('team_member')
          .update({ ...x, job_title: x.job_title || null, version })
          .eq('id', member!.id)
          .select(),
      );
      refresh(qc, 'team_member');
      return row?.version;
    },
  });
  // The email and Discord username keep a Save button: the email is how this person signs in and where alerts
  // go, and a new Discord username starts a Discord check, so a half typed address must never be stored.
  const contactChanged =
    !!member &&
    (f.email.trim() !== member.email ||
      cleanUsername(f.discord_username) !== (member.discord_username ?? ''));

  async function save(another = false) {
    setErr(null);
    if (!v.submit()) return;
    setSaving(true);
    try {
      const row = {
        ...f,
        name: f.name.trim(),
        email: f.email.trim(),
        discord_username: cleanUsername(f.discord_username) || null,
      };
      if (member) {
        const [saved] = check(
          await supabase
            .from('team_member')
            .update({
              email: row.email,
              discord_username: row.discord_username,
              is_placeholder: false,
              version: auto.version,
            })
            .eq('id', member.id)
            .select(),
        );
        if (saved) auto.adoptVersion(saved.version);
      } else {
        check(await supabase.from('team_member').insert(row));
      }
      toast.success(member ? 'Email and Discord saved' : `${row.name} added`);
      refresh(qc, 'team_member');
      if (another) {
        // Save and add another: an empty form for the next person (decision 259).
        setF({ ...f, name: '', email: '', discord_username: '', job_title: '' });
        v.reset();
        return;
      }
      if (!member) onClose();
    } catch (e) {
      setErr(e);
      toast.error(member ? 'The changes were not saved' : 'The team member was not added');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={member ? member.name : 'Add team member'}
      description={
        member?.is_placeholder
          ? 'This person came with the starting data. Replace their name, email and Discord username.'
          : undefined
      }
      footer={
        <div className="flex flex-wrap items-center gap-2">
          {member ? (
            <>
              <Button variant="secondary" onClick={onClose}>
                Done
              </Button>
              <SaveState status={auto.status} waiting={auto.dirty} />
            </>
          ) : (
            <>
              <Button onClick={() => void save()} loading={saving}>
                Add team member
              </Button>
              <Button variant="secondary" onClick={() => void save(true)} loading={saving}>
                Save and add another
              </Button>
              <Button variant="secondary" onClick={onClose}>
                Cancel
              </Button>
            </>
          )}
          {member && isAdmin && (
            <Button
              variant="ghost"
              className="ml-auto"
              onClick={async () => {
                try {
                  await rpc('send_test_alert', { p_team_member_id: member.id });
                  toast.success('Test alert sent');
                } catch (e) {
                  setErr(e);
                }
              }}
            >
              <BellRing className="h-4 w-4" aria-hidden /> Send test alert
            </Button>
          )}
        </div>
      }
    >
      <div className="space-y-4">
        <Field label="Name" required error={v.show('name')}>
          <Input
            value={f.name}
            onBlur={() => (v.touch('name')(), auto.flush())}
            onChange={(e) => setF({ ...f, name: e.target.value })}
          />
        </Field>
        <Field label="Email" required error={v.show('email')}>
          <Input
            value={f.email}
            onBlur={v.touch('email')}
            onChange={(e) => setF({ ...f, email: e.target.value })}
          />
        </Field>
        <Field
          label="Discord username (optional)"
          hint={
            locked
              ? BETA_LOCK_NOTE
              : 'For example maya.k, without @. Used to tag this person and send them direct messages. Without it they get email.'
          }
          error={v.show('discord_username')}
        >
          <Input
            value={f.discord_username}
            disabled={locked}
            onBlur={v.touch('discord_username')}
            onChange={(e) => setF({ ...f, discord_username: e.target.value })}
            autoComplete="off"
          />
        </Field>
        {contactChanged && (
          <Button variant="secondary" onClick={() => void save()} loading={saving}>
            Save email and Discord
          </Button>
        )}
        {member?.discord_username && (
          <div className="flex flex-wrap items-center gap-2">
            <DiscordStatus status={member.discord_status} problem={member.discord_problem} />
            <Button
              size="sm"
              variant="outline"
              onClick={async () => {
                try {
                  await rpc('check_discord', { p_kind: 'team', p_id: member.id });
                  toast.success(
                    'Checking Discord, usually a few seconds. The result shows here by itself.',
                  );
                  refresh(qc, 'team_member');
                } catch (e) {
                  setErr(e);
                }
              }}
            >
              Check Discord
            </Button>
          </div>
        )}
        <Field
          label="Job title"
          hint="Optional. Shown only; what someone does comes from where they are assigned."
        >
          <Input
            value={f.job_title}
            onBlur={auto.flush}
            onChange={(e) => setF({ ...f, job_title: e.target.value })}
          />
        </Field>
        <div className="space-y-2 rounded-md border border-border p-3">
          <Checkbox
            label="Send a daily summary"
            hint="One message each morning with the tasks waiting for this person. Nothing is sent when there is nothing to do."
            checked={f.receives_digest}
            onChange={(c) => setF({ ...f, receives_digest: c })}
          />
          {f.receives_digest && (
            <Field label="Send it by">
              <Select
                value={f.digest_channel}
                onChange={(e) => setF({ ...f, digest_channel: e.target.value })}
                className="w-56"
              >
                {Object.entries(DIGEST_LABEL).map(([k, l]) => (
                  <option key={k} value={k}>
                    {l}
                  </option>
                ))}
              </Select>
            </Field>
          )}
        </div>
        <Checkbox
          label="In use"
          hint="People who are not in use are not tagged or reminded."
          checked={f.active}
          onChange={(c) => setF({ ...f, active: c })}
        />
        <ErrorText error={err} />
        {member && <AccessSection member={member} onDone={onClose} />}
        {member && !member.access_removed_at && (
          <div className="space-y-2 rounded-md border border-border p-3">
            <div className="text-sm font-semibold">Delete</div>
            <p className="text-sm text-muted-foreground">
              Deletes this person and their roles for good. To keep them from signing in again,
              remove their access instead.
            </p>
            <DeleteButton kind="team_member" id={member.id} onDeleted={onClose} />
          </div>
        )}
      </div>
    </Drawer>
  );
}

/** Remove access: the person can no longer sign in, see data or be tagged. */
function AccessSection({ member, onDone }: { member: TeamMember; onDone: () => void }) {
  const { account } = useAuth();
  const confirm = useConfirm();
  const qc = useQueryClient();
  const [err, setErr] = useState<unknown>(null);
  const removed = !!member.access_removed_at;
  const self = account?.member?.id === member.id;
  const isAdmin = !!useMe()?.is_admin;
  return (
    <div className="space-y-2 rounded-md border border-destructive/40 p-3">
      <div className="text-sm font-semibold text-danger-strong">
        {removed ? 'Access removed' : 'Access'}
      </div>
      <p className="text-sm text-muted-foreground">
        {removed
          ? 'This person cannot sign in. Their past work stays in Activity history.'
          : self
            ? 'You cannot remove your own access.'
            : !isAdmin
              ? 'Only an admin can remove access.'
              : 'Removing access stops this person from signing in and from being tagged or reminded.'}
      </p>
      {!self && isAdmin && (
        <Button
          size="sm"
          variant={removed ? 'secondary' : 'destructive'}
          onClick={async () => {
            if (
              !removed &&
              !(await confirm({
                title: `Remove access for ${member.name}?`,
                body: 'They are signed out at their next action and cannot sign in again until you give access back.',
                danger: true,
                confirmLabel: 'Remove access',
              }))
            )
              return;
            try {
              await rpc('set_member_access', {
                p_team_member_id: member.id,
                p_has_access: removed,
              });
              toast.success(removed ? 'Access given back' : 'Access removed');
              refresh(qc, 'team_member', 'domain_team', 'module_operations', 'module');
              onDone();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          {removed ? 'Give access back' : 'Remove access'}
        </Button>
      )}
      <ErrorText error={err} />
    </div>
  );
}
