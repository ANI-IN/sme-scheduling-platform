// Builds the workflows to import into your n8n, from the base files in n8n/:
//   n8n/WF*.json            the source: edit these.
//   n8n/instance.json       your account values (copy n8n/instance.example.json; not in git).
//   n8n/generated/*.json    written by this script: import or compare these (not in git).
//
//   npm run n8n-export -w scripts
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const DIR = resolve(import.meta.dirname, '../../n8n');
const SETTINGS = join(DIR, 'instance.json');
if (!existsSync(SETTINGS)) {
  console.error(
    'Copy n8n/instance.example.json to n8n/instance.json and fill in your own values first.',
  );
  process.exit(2);
}

type Instance = {
  /** Used in webhook ids, so exporting twice gives the same files. */
  key: string;
  /** Shown in each workflow name, "[title] WF1 ...". */
  title: string;
  /** The n8n tag put on each workflow. */
  tag: string;
  /** Put in front of every webhook path; may be empty. */
  pathPrefix: string;
  supabaseUrl: string;
  n8nUrl: string;
  /** The Google Drive folder for the daily backup. */
  backupFolderId: string;
  /** The Gmail label ID that marks a reply as read. */
  processedLabelId: string;
  /** The Discord channel where WF5 posts when the database cannot be reached. */
  adminChannelId: string;
  /** The name of each credential in your n8n, by its name in the base files. */
  credentials: Record<string, string>;
};
const env = JSON.parse(readFileSync(SETTINGS, 'utf8')) as Instance;

/** A stable id per environment, so re-exporting gives the same files. */
function uuidFor(seed: string): string {
  const h = createHash('sha1').update(seed).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

type Node = {
  name: string;
  parameters?: Record<string, unknown>;
  credentials?: Record<string, { id?: string; name: string }>;
  webhookId?: string;
};
type Workflow = { name: string; nodes: Node[]; tags?: unknown[]; [k: string]: unknown };

const p0 = (n: Node) => (n.parameters ?? {}) as Record<string, unknown>;

const out = join(DIR, 'generated');
{
  mkdirSync(out, { recursive: true });
  for (const file of readdirSync(DIR).filter((f) => /^WF\d.*\.json$/.test(f))) {
    const wf = JSON.parse(readFileSync(join(DIR, file), 'utf8')) as Workflow;
    wf.name = `[${env.title}] ${wf.name}`;
    wf.tags = [{ name: env.tag }];
    for (const n of wf.nodes) {
      for (const c of Object.values(n.credentials ?? {})) {
        delete c.id;
        const name = env.credentials[c.name];
        if (!name)
          throw new Error(`n8n/instance.json has no name for the credential "${c.name}" (${file})`);
        c.name = name;
      }
      // The backup folder of this environment (Upload to Google Drive, List backups).
      for (const v of [
        p0(n).folderId,
        (p0(n).filter as Record<string, unknown> | undefined)?.folderId,
      ])
        if (
          v &&
          typeof v === 'object' &&
          (v as { value?: string }).value === 'REPLACE_WITH_DRIVE_FOLDER_ID'
        )
          (v as { value: string }).value = env.backupFolderId;
      // WF1 "Label as processed": the label ID of this environment's mailbox.
      const labels = p0(n).labelIds;
      if (Array.isArray(labels))
        p0(n).labelIds = labels.map((l) =>
          l === 'REPLACE_WITH_PROCESSED_LABEL_ID' ? env.processedLabelId : l,
        );
      if (n.webhookId) n.webhookId = uuidFor(`${env.key}:${file}:${n.name}`);
      const p = n.parameters ?? {};
      if (typeof p.path === 'string' && env.pathPrefix) p.path = env.pathPrefix + p.path;
      if (typeof p.jsCode === 'string') {
        p.jsCode = p.jsCode
          .replace('https://YOUR-PROJECT.supabase.co', env.supabaseUrl)
          .replace('YOUR-ADMIN-CHANNEL-ID', env.adminChannelId)
          .replace(
            'https://YOUR-N8N/webhook/sme-poke',
            `${env.n8nUrl}/webhook/${env.pathPrefix}sme-poke`,
          )
          .replace('/webhook/sme-poke', `/webhook/${env.pathPrefix}sme-poke`);
      }
      // Sticky notes describe the webhook paths: keep them true for this environment.
      if (typeof p.content === 'string' && env.pathPrefix) {
        p.content = p.content
          .replaceAll('/webhook/respond', `/webhook/${env.pathPrefix}respond`)
          .replaceAll('/webhook/sme-poke', `/webhook/${env.pathPrefix}sme-poke`);
      }
    }
    writeFileSync(join(out, file), JSON.stringify(wf, null, 2) + '\n');
  }
  console.log('Wrote n8n/generated/');
}
