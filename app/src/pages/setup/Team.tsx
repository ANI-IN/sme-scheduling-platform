import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { BellRing, Plus, Users } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { useTeam, type TeamMember } from '@/lib/data';
import { isDiscordId, isEmail } from '@/lib/validation';
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

export const ROLE_LABEL: Record<string, string> = {
  Ops: 'Operations',
  PM: 'Product manager',
  Lead: 'Lead',
};
const DIGEST_LABEL: Record<string, string> = {
  Discord: 'Discord',
  Email: 'Email',
  Both: 'Discord and email',
};

export default function Team() {
  const { data, isLoading, error } = useTeam();
  const [editing, setEditing] = useState<TeamMember | 'new' | null>(null);
  return (
    <div>
      <PageHeader
        title="Team"
        description="The people who run classes. Module owners, domain leads and the operations team are chosen from this list."
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
          Add the people who own modules or handle operations.
        </Empty>
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Name</th>
                <th className={th}>Role</th>
                <th className={th}>Email</th>
                <th className={th}>Discord</th>
                <th className={th}>Daily summary</th>
              </tr>
            </thead>
            <tbody>
              {(data ?? []).map((t) => (
                <tr key={t.id} className={trowClick} onClick={() => setEditing(t)}>
                  <td className={td}>
                    <span className="font-medium">{t.name}</span>{' '}
                    {t.is_placeholder && <Badge tone="warning">Needs real details</Badge>}
                    {!t.active && <Badge>Inactive</Badge>}
                  </td>
                  <td className={td}>{ROLE_LABEL[t.label] ?? t.label}</td>
                  <td className={`${td} text-muted-foreground`}>{t.email}</td>
                  <td className={td}>
                    {t.discord_user_id ? (
                      <Badge tone="success">Added</Badge>
                    ) : (
                      <Badge tone="warning">Missing</Badge>
                    )}
                  </td>
                  <td className={td}>
                    {t.receives_digest ? DIGEST_LABEL[t.digest_channel] : 'Off'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {editing && (
        <MemberDrawer
          member={editing === 'new' ? null : editing}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function MemberDrawer({ member, onClose }: { member: TeamMember | null; onClose: () => void }) {
  const qc = useQueryClient();
  const [f, setF] = useState({
    name: member?.name ?? '',
    email: member?.email ?? '',
    discord_user_id: member?.discord_user_id ?? '',
    label: member?.label ?? 'Ops',
    receives_digest: member?.receives_digest ?? true,
    digest_channel: member?.digest_channel ?? 'Discord',
    active: member?.active ?? true,
  });
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const v = useFormErrors({
    name: !f.name.trim() ? 'Enter a name.' : undefined,
    email: !isEmail(f.email) ? 'Enter a valid email address.' : undefined,
    discord_user_id:
      f.discord_user_id && !isDiscordId(f.discord_user_id)
        ? 'A Discord user ID is 17 to 20 digits.'
        : undefined,
  });

  async function save() {
    setErr(null);
    if (!v.submit()) return;
    setSaving(true);
    try {
      const row = {
        ...f,
        name: f.name.trim(),
        email: f.email.trim(),
        discord_user_id: f.discord_user_id.trim() || null,
      };
      if (member) {
        check(
          await supabase
            .from('team_member')
            .update({ ...row, is_placeholder: false, version: member.version })
            .eq('id', member.id)
            .select(),
        );
      } else {
        check(await supabase.from('team_member').insert(row));
      }
      toast.success(member ? 'Changes saved' : 'Team member added');
      await qc.invalidateQueries();
      onClose();
    } catch (e) {
      setErr(e);
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
          ? 'This person came with the starting data. Replace their name, email and Discord user ID.'
          : undefined
      }
      footer={
        <div className="flex flex-wrap items-center gap-2">
          <Button onClick={() => void save()} loading={saving}>
            {member ? 'Save changes' : 'Add team member'}
          </Button>
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
          {member && (
            <Button
              variant="ghost"
              className="ml-auto"
              onClick={async () => {
                try {
                  await rpc('send_test_alert', { p_team_member_id: member.id });
                  await poke();
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
            onBlur={v.touch('name')}
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
          label="Discord user ID"
          hint="Used to tag this person in alerts. In Discord, turn on Developer Mode (User Settings, Advanced), then right click the person and choose Copy User ID."
          error={v.show('discord_user_id')}
        >
          <Input
            value={f.discord_user_id}
            onBlur={v.touch('discord_user_id')}
            onChange={(e) => setF({ ...f, discord_user_id: e.target.value })}
          />
        </Field>
        <Field label="Role">
          <Select value={f.label} onChange={(e) => setF({ ...f, label: e.target.value })}>
            {Object.entries(ROLE_LABEL).map(([k, l]) => (
              <option key={k} value={k}>
                {l}
              </option>
            ))}
          </Select>
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
          label="Active"
          hint="Inactive people are not tagged or reminded."
          checked={f.active}
          onChange={(c) => setF({ ...f, active: c })}
        />
        <ErrorText error={err} />
      </div>
    </Drawer>
  );
}
