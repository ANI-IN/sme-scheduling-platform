import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { ShieldCheck, UserPlus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useMe, useSystem, useTeam } from '@/lib/data';
import { fmtLocal } from '@/lib/time';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Field,
  Input,
  Notice,
  PageHeader,
  Section,
} from '@/components/ui';

/** Release 3, decisions 276, 277, 286 and 287: what only admins change, in one place. */
export default function Admin() {
  const me = useMe();
  if (!me) return null;
  if (!me.is_admin) {
    return (
      <div className="space-y-6">
        <PageHeader title="Admin" />
        <Notice tone="info">
          Only an admin can see this page. Ask an admin if you need a change to who may sign in or
          who may receive messages.
        </Notice>
      </div>
    );
  }
  return (
    <div className="space-y-6">
      <PageHeader
        title="Admin"
        description="Who may sign in, who may receive messages, and who the admins are. Every change is saved in Activity history."
      />
      <SignInSection />
      <BetaListSection />
      <RecipientsSection />
      <AdminsSection />
    </div>
  );
}

const useBetaList = () =>
  useQuery({
    queryKey: ['beta_access'],
    queryFn: async () =>
      check(await supabase.from('beta_access').select('*').order('email')) as {
        email: string;
        note: string | null;
        added_at: string;
      }[],
  });

function SignInSection() {
  const { data } = useSystem();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const mode =
    (data?.config as { sign_in_mode?: string } | undefined)?.sign_in_mode ?? 'Allowed email domain';
  const domain = data?.config.company_email_domain ?? '';
  const set = async (next: string) => {
    if (next === mode) return;
    const ok = await confirm({
      title:
        next === 'Beta list'
          ? 'Only let people on the beta list sign in?'
          : `Let anyone with an @${domain} account sign in?`,
      body:
        next === 'Beta list'
          ? 'Anyone who is not on the beta list is signed out at once and cannot sign in again until an admin adds them.'
          : `Everyone with a company Google account (@${domain}) can sign in, whether or not they are on the beta list.`,
      confirmLabel: next === 'Beta list' ? 'Use the beta list' : 'Let everyone in',
      danger: next !== 'Beta list',
    });
    if (!ok) return;
    setErr(null);
    try {
      await rpc('set_sign_in_mode', { p_mode: next });
      toast.success('Who may sign in is changed');
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  };
  return (
    <Section
      title="Who may sign in"
      description="During the beta only colleagues on the beta list get in. Refused sign ins are in Activity history."
      actions={
        <Badge tone={mode === 'Beta list' ? 'success' : 'warning'}>
          {mode === 'Beta list' ? 'Beta list only' : `Anyone at @${domain}`}
        </Badge>
      }
    >
      <div className="flex flex-wrap gap-2">
        <Button
          variant={mode === 'Beta list' ? 'primary' : 'outline'}
          onClick={() => set('Beta list')}
        >
          People on the beta list
        </Button>
        <Button
          variant={mode !== 'Beta list' ? 'primary' : 'outline'}
          onClick={() => set('Allowed email domain')}
        >
          Anyone with an @{domain} account
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}

function BetaListSection() {
  const list = useBetaList();
  const team = useTeam();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const { data } = useSystem();
  const domain = data?.config.company_email_domain ?? '';
  const [email, setEmail] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const add = async () => {
    setBusy(true);
    setErr(null);
    try {
      await rpc('beta_list_add', { p_email: email, p_note: note || undefined });
      toast.success(`${email.trim().toLowerCase()} is on the beta list`);
      setEmail('');
      setNote('');
      await qc.invalidateQueries({ queryKey: ['beta_access'] });
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };
  const remove = async (e: string) => {
    const ok = await confirm({
      title: `Take ${e} off the beta list?`,
      body: 'If they are signed in, they are signed out at once. Their work stays.',
      confirmLabel: 'Take off the list',
      danger: true,
    });
    if (!ok) return;
    try {
      await rpc('beta_list_remove', { p_email: e });
      toast.success(`${e} is no longer on the beta list`);
      await qc.invalidateQueries({ queryKey: ['beta_access'] });
    } catch (x) {
      setErr(x);
    }
  };
  const signedIn = new Set(
    (team.data ?? []).filter((t) => t.auth_user_id).map((t) => t.email.toLowerCase()),
  );
  return (
    <Section
      title="Beta list"
      description={`Colleagues who may sign in while sign in is limited to the beta list. Only @${domain} addresses.`}
    >
      <form
        className="mb-4 grid gap-3 sm:grid-cols-[2fr_2fr_auto] sm:items-end"
        onSubmit={(e) => {
          e.preventDefault();
          void add();
        }}
      >
        <Field label="Email">
          <Input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder={`name@${domain}`}
            required
          />
        </Field>
        <Field label="Note (optional)">
          <Input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="For example: Agentic AI operations"
          />
        </Field>
        <Button type="submit" loading={busy} disabled={!email.trim()}>
          <UserPlus className="size-4" aria-hidden /> Add to the beta list
        </Button>
      </form>
      <ErrorText error={err} />
      {list.data && list.data.length === 0 ? (
        <Empty title="Nobody is on the beta list yet">
          Add yourself first, then your colleagues.
        </Empty>
      ) : (
        <ul className="divide-y divide-border rounded-md border border-border">
          {(list.data ?? []).map((b) => (
            <li key={b.email} className="flex flex-wrap items-center gap-2 px-3 py-2 text-sm">
              <span className="font-medium">{b.email}</span>
              {signedIn.has(b.email) ? (
                <Badge tone="success">Signed in before</Badge>
              ) : (
                <Badge>Not signed in yet</Badge>
              )}
              {b.note && <span className="text-muted-foreground">{b.note}</span>}
              <span className="ml-auto text-xs text-muted-foreground">
                Added {fmtLocal(b.added_at)}
              </span>
              <Button size="sm" variant="ghost" onClick={() => void remove(b.email)}>
                Take off the list
              </Button>
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

const BETA = 'Test instructors and signed in colleagues';

function RecipientsSection() {
  const { data } = useSystem();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const cfg = (data?.config ?? {}) as {
    recipient_email_domains?: string[];
    message_recipients?: string;
    daily_email_cap?: number;
  };
  const [domains, setDomains] = useState<string | null>(null);
  const [cap, setCap] = useState<string | null>(null);
  const [err, setErr] = useState<unknown>(null);
  const shownDomains = domains ?? (cfg.recipient_email_domains ?? []).join(', ');
  const shownCap = cap ?? String(cfg.daily_email_cap ?? 1000);
  const recipients = cfg.message_recipients ?? 'Anyone';
  const save = async (nextRecipients: string) => {
    const list = shownDomains
      .split(/[,\s]+/)
      .map((x) => x.trim())
      .filter(Boolean);
    if (nextRecipients !== recipients) {
      const ok = await confirm({
        title:
          nextRecipients === BETA
            ? 'Only message test instructors and signed in colleagues?'
            : 'Let messages reach anyone?',
        body:
          nextRecipients === BETA
            ? 'Real instructors are never contacted, direct messages go only to signed in colleagues, and messages may only tag them. Blocked messages are listed in Activity history.'
            : 'Messages go to real instructors again, as in normal Production use. Do this only when the beta is over.',
        confirmLabel:
          nextRecipients === BETA ? 'Use the beta setting' : 'Let messages reach anyone',
        danger: nextRecipients !== BETA,
      });
      if (!ok) return;
    }
    setErr(null);
    try {
      await rpc('set_recipient_rules', {
        p_email_domains: list,
        p_message_recipients: nextRecipients,
        p_daily_email_cap: Number(shownCap),
      });
      toast.success('Who may receive messages is saved');
      setDomains(null);
      setCap(null);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  };
  return (
    <Section
      title="Who may receive messages"
      description="Checked for every person a message goes to or tags, when it is queued and again when it is sent."
      actions={
        <Badge tone={recipients === BETA ? 'success' : 'warning'}>
          {recipients === BETA ? 'Beta: test instructors and colleagues' : 'Anyone'}
        </Badge>
      }
    >
      <div className="grid gap-3 sm:grid-cols-2">
        <Field
          label="Email only to these domains"
          hint="Separate domains with commas. Leave empty to allow any address."
        >
          <Input
            value={shownDomains}
            onChange={(e) => setDomains(e.target.value)}
            placeholder="yourcompany.com"
          />
        </Field>
        <Field
          label="Emails a day at most"
          hint="Google allows about 2,000 a day for the whole mailbox. Over the limit, emails wait."
        >
          <Input
            type="number"
            min={1}
            max={2000}
            value={shownCap}
            onChange={(e) => setCap(e.target.value)}
          />
        </Field>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <Button
          onClick={() => void save(BETA)}
          variant={recipients === BETA ? 'primary' : 'outline'}
        >
          <ShieldCheck className="size-4" aria-hidden /> Test instructors and signed in colleagues
        </Button>
        <Button
          onClick={() => void save('Anyone')}
          variant={recipients !== BETA ? 'primary' : 'outline'}
        >
          Anyone
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}

function AdminsSection() {
  const team = useTeam();
  const me = useMe();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const people = (team.data ?? []).filter((t) => t.auth_user_id && !t.access_removed_at);
  const admins = people.filter((t) => t.is_admin);
  const set = async (id: string, name: string, admin: boolean) => {
    const ok = await confirm({
      title: admin ? `Make ${name} an admin?` : `Remove admin rights from ${name}?`,
      body: admin
        ? 'Admins can change who may sign in, who may receive messages, Discord server approvals, Pause all messages and every setting that affects everyone.'
        : 'They keep their access and their work; they can no longer change settings that affect everyone.',
      confirmLabel: admin ? 'Make admin' : 'Remove admin rights',
      danger: !admin,
    });
    if (!ok) return;
    setErr(null);
    try {
      await rpc('set_admin', { p_team_member_id: id, p_admin: admin });
      toast.success(admin ? `${name} is an admin` : `${name} is no longer an admin`);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  };
  return (
    <Section
      title="Admins"
      description="Every admin can do everything here. There is always at least one admin."
    >
      <ErrorText error={err} />
      <ul className="divide-y divide-border rounded-md border border-border">
        {people.map((t) => (
          <li key={t.id} className="flex flex-wrap items-center gap-2 px-3 py-2 text-sm">
            <span className="font-medium">{t.name}</span>
            <span className="text-muted-foreground">{t.email}</span>
            {t.is_admin && <Badge tone="success">Admin</Badge>}
            {t.id === me?.id && <Badge>You</Badge>}
            <span className="ml-auto" />
            {t.is_admin ? (
              <Button
                size="sm"
                variant="ghost"
                disabled={admins.length <= 1}
                title={admins.length <= 1 ? 'There must always be at least one admin.' : undefined}
                onClick={() => void set(t.id, t.name, false)}
              >
                Remove admin rights
              </Button>
            ) : (
              <Button size="sm" variant="outline" onClick={() => void set(t.id, t.name, true)}>
                Make admin
              </Button>
            )}
          </li>
        ))}
      </ul>
      <p className="mt-2 text-xs text-muted-foreground">
        Only people who have signed in can be admins.
      </p>
    </Section>
  );
}
