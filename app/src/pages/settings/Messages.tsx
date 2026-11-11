import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { poke, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useUnsavedChanges } from '@/lib/unsaved';
import { useConfirm } from '@/components/Confirm';
import { LastChanged } from '@/components/LastChanged';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Field,
  Input,
  PageHeader,
  Section,
  SkeletonRows,
  Textarea,
  cn,
} from '@/components/ui';

type Template = {
  template_id: string;
  name: string;
  subject: string;
  body: string;
  default_subject: string;
  default_body: string;
  required: string[];
  changed: boolean;
  updated_at: string | null;
  updated_by: string | null;
};

/** Details that are filled in when a message is sent. */
const DETAILS: Record<string, string> = {
  first_name: 'Instructor first name',
  name: 'Instructor full name',
  module: 'Module name',
  domain: 'Domain name',
  classes: 'Every class with date and time, in the time zone of the class',
  first_class: 'Date and time of the first class',
  weekday: 'Weekday of the first class',
  deadline: 'When to reply by',
  reply_by: 'A "Please reply by" line, when there is a reply time',
  help: 'How to get help before class (Need help, or a reply to the module owners)',
  contact: 'Module owners',
  days: 'Days until the class',
  what: 'What was cancelled',
  helper: 'Who will reply to a help request',
  by: 'When they will reply',
  text: 'The reply text',
  from: 'Who replied',
};

export default function Messages() {
  const { domain } = useDomain();
  const templates = useQuery({
    queryKey: ['message_template', domain?.id],
    enabled: !!domain,
    queryFn: async () =>
      (await rpc('message_templates', { p_domain_id: domain!.id })) as unknown as Template[],
  });
  const [open, setOpen] = useState<string | null>(null);
  const current = (templates.data ?? []).find((t) => t.template_id === open);
  return (
    <div>
      <PageHeader
        title="Message templates"
        description={
          domain
            ? `The messages instructors get for ${domain.name}. Details in braces, like {module}, are filled in when a message is sent. Buttons such as Yes and No are added automatically.`
            : 'Choose a domain first.'
        }
      />
      {!domain ? (
        <Empty title="No domain yet">Create a domain on the Domains page first.</Empty>
      ) : templates.isLoading ? (
        <SkeletonRows rows={8} />
      ) : (
        <div className="grid gap-4 lg:grid-cols-[18rem_1fr]">
          <ul className="space-y-1" aria-label="Messages">
            {(templates.data ?? []).map((t) => (
              <li key={t.template_id}>
                <button
                  type="button"
                  onClick={() => setOpen(t.template_id)}
                  aria-current={open === t.template_id ? 'true' : undefined}
                  className={cn(
                    'flex w-full items-center justify-between gap-2 rounded-md px-3 py-2 text-left text-sm hover:bg-muted',
                    open === t.template_id && 'bg-primary-soft font-medium',
                  )}
                >
                  {t.name}
                  {t.changed && <Badge tone="info">Changed</Badge>}
                </button>
              </li>
            ))}
          </ul>
          {current ? (
            <Editor key={current.template_id} domainId={domain.id} t={current} />
          ) : (
            <Empty title="Choose a message">
              Pick a message on the left to read or change its text.
            </Empty>
          )}
        </div>
      )}
    </div>
  );
}

function Editor({ domainId, t }: { domainId: string; t: Template }) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [subject, setSubject] = useState(t.subject);
  const [body, setBody] = useState(t.body);
  const [preview, setPreview] = useState<{
    subject: string;
    body: string;
    problems: string[];
  } | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const dirty = subject !== t.subject || body !== t.body;
  useUnsavedChanges(dirty);

  // Live preview with real details of an upcoming class week (or sample details).
  useEffect(() => {
    const h = setTimeout(() => {
      void rpc('preview_message_template', {
        p_domain_id: domainId,
        p_template_id: t.template_id,
        p_subject: subject,
        p_body: body,
      }).then(
        (r) => setPreview(r as never),
        () => {},
      );
    }, 300);
    return () => clearTimeout(h);
  }, [domainId, t.template_id, subject, body]);

  const refresh = () => qc.invalidateQueries({ queryKey: ['message_template'] });
  const act = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    setErr(null);
    try {
      await fn();
      toast.success(ok);
      await refresh();
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Section
      title={t.name}
      description={
        t.required.length
          ? `Must include ${t.required.map((r) => `{${r}}`).join(', ')}.`
          : 'Any text is fine.'
      }
    >
      <div className="grid gap-5 xl:grid-cols-2">
        <div className="space-y-3">
          <Field label="Subject (email) or title (Discord)">
            <Input value={subject} onChange={(e) => setSubject(e.target.value)} />
          </Field>
          <Field label="Message">
            <Textarea value={body} onChange={(e) => setBody(e.target.value)} className="min-h-56" />
          </Field>
          <details>
            <summary className="cursor-pointer text-sm font-medium text-link">
              Details you can use
            </summary>
            <ul className="mt-2 grid gap-1 text-sm">
              {Object.entries(DETAILS).map(([k, label]) => (
                <li key={k}>
                  <button
                    type="button"
                    className="font-mono text-link hover:underline"
                    onClick={() => setBody((b) => `${b}{${k}}`)}
                    title="Add to the end of the message"
                  >
                    {`{${k}}`}
                  </button>{' '}
                  <span className="text-muted-foreground">{label}</span>
                </li>
              ))}
            </ul>
          </details>
        </div>
        <div>
          <div className="mb-1 text-sm font-medium">Preview</div>
          <div className="rounded-md border border-border bg-muted/40 p-3 text-sm">
            <div className="mb-2 font-semibold">{preview?.subject ?? subject}</div>
            <div className="whitespace-pre-line">{preview?.body ?? body}</div>
            <div className="mt-3 text-xs text-muted-foreground">
              The buttons for this message are added below the text.
            </div>
          </div>
          {preview && preview.problems.length > 0 && (
            <ul className="mt-2 space-y-1 text-sm text-danger-strong" role="alert">
              {preview.problems.map((x) => (
                <li key={x}>{x}</li>
              ))}
            </ul>
          )}
        </div>
      </div>
      <ErrorText error={err} />
      <div className="mt-4 flex flex-wrap items-center gap-2">
        <Button
          loading={busy}
          disabled={!dirty || (preview?.problems.length ?? 0) > 0}
          onClick={() =>
            act(
              () =>
                rpc('save_message_template', {
                  p_domain_id: domainId,
                  p_template_id: t.template_id,
                  p_subject: subject,
                  p_body: body,
                }),
              'Message saved',
            )
          }
        >
          Save changes
        </Button>
        <Button
          variant="secondary"
          disabled={busy || (preview?.problems.length ?? 0) > 0}
          onClick={() =>
            act(async () => {
              await rpc('send_template_test', {
                p_domain_id: domainId,
                p_template_id: t.template_id,
                p_subject: subject,
                p_body: body,
              });
              await poke();
            }, 'Test message sent to the alert channel')
          }
        >
          Send test message
        </Button>
        {(t.changed || dirty) && (
          <Button
            variant="ghost"
            disabled={busy}
            onClick={async () => {
              if (
                !(await confirm({
                  title: 'Go back to the default text?',
                  body: 'Your own text for this message is removed.',
                  confirmLabel: 'Reset to default',
                }))
              )
                return;
              setSubject(t.default_subject);
              setBody(t.default_body);
              if (t.changed)
                await act(
                  () =>
                    rpc('reset_message_template', {
                      p_domain_id: domainId,
                      p_template_id: t.template_id,
                    }),
                  'Back to the default text',
                );
            }}
          >
            Reset to default
          </Button>
        )}
        <div className="ml-auto">
          {t.changed && <LastChanged at={t.updated_at} by={t.updated_by} />}
        </div>
      </div>
    </Section>
  );
}
