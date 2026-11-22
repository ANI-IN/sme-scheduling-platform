// Builds the two n8n workflow sets from the base files in n8n/:
//   n8n/sandbox/*.json     the live workflows: named "[Production] …" since M5, tagged Sandbox, Sandbox credentials
//                          and webhook paths (both kept so nothing that already works changes)
//   n8n/production/*.json  named "[Production] …", tagged Production, Production credentials
// Both sets can live in one n8n instance (different webhook paths and credential names) or in two.
//
//   npm run n8n-export -w scripts
import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const DIR = resolve(import.meta.dirname, '../../n8n');
// The values already known for each environment (docs/CONFIGURATION.md). Not secrets: the poke key stays a
// placeholder, and production values are filled in later.
const ENVS = [
  {
    key: 'sandbox',
    label: 'Sandbox',
    // The live workflows since the switch on 22 November (M5): shown as Production, credentials and tags unchanged.
    title: 'Production',
    pathPrefix: 'sandbox-',
    supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
    n8nUrl: 'https://your-instance.app.n8n.cloud',
    backupFolderId: 'your-drive-folder-id',
    // The Gmail label "SME Scheduling/Processed" in the Sandbox mailbox (WF1 labels the replies it read).
    processedLabelId: 'Label_1',
  },
  {
    key: 'production',
    label: 'Production',
    title: 'Production',
    pathPrefix: '',
    supabaseUrl: 'https://YOUR-PRODUCTION-PROJECT.supabase.co',
    n8nUrl: 'https://your-instance.app.n8n.cloud',
    backupFolderId: 'REPLACE_WITH_PRODUCTION_DRIVE_FOLDER_ID',
    processedLabelId: 'REPLACE_WITH_PRODUCTION_PROCESSED_LABEL_ID',
  },
] as const;

/**
 * The exact credential names in n8n (decision 264). Sandbox uses the credentials that already exist:
 * "Gmail Sandbox" (Gmail, Sign in with Google), "Discord Bot Sandbox" (Discord Bot) and "Google Drive Backups"
 * (Google Drive, Sign in with Google).
 */
const CREDENTIALS: Record<string, Record<'sandbox' | 'production', string>> = {
  Gmail: { sandbox: 'Gmail Sandbox', production: 'Gmail Production' },
  'Discord Bot': { sandbox: 'Discord Bot Sandbox', production: 'Discord Bot Production' },
  'Google Drive Backups': {
    sandbox: 'Google Drive Backups',
    production: 'Google Drive Backups Production',
  },
  'Supabase secret key': { sandbox: 'Supabase Sandbox', production: 'Supabase Production' },
  'Poke secret': { sandbox: 'Poke Secret Sandbox', production: 'Poke Secret Production' },
};

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

for (const env of ENVS) {
  const out = join(DIR, env.key);
  mkdirSync(out, { recursive: true });
  for (const file of readdirSync(DIR).filter((f) => /^WF\d.*\.json$/.test(f))) {
    const wf = JSON.parse(readFileSync(join(DIR, file), 'utf8')) as Workflow;
    wf.name = `[${env.title}] ${wf.name}`;
    wf.tags = [{ name: env.label }];
    for (const n of wf.nodes) {
      for (const c of Object.values(n.credentials ?? {})) {
        delete c.id;
        const name = CREDENTIALS[c.name]?.[env.key];
        if (!name)
          throw new Error(`No ${env.label} name for the credential "${c.name}" in ${file}`);
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
  console.log(`Wrote n8n/${env.key}/`);
}
