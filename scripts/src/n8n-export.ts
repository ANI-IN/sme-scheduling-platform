// Builds the two n8n workflow sets from the base files in n8n/:
//   n8n/sandbox/*.json     named "[Sandbox] …", tagged Sandbox, Sandbox credentials and webhook paths
//   n8n/production/*.json  named "[Production] …", tagged Production, Production credentials
// Both sets can live in one n8n instance (different webhook paths and credential names) or in two.
//
//   npm run n8n-export -w scripts
import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const DIR = resolve(import.meta.dirname, '../../n8n');
const ENVS = [
  { key: 'sandbox', label: 'Sandbox', pathPrefix: 'sandbox-' },
  { key: 'production', label: 'Production', pathPrefix: '' },
] as const;

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

for (const env of ENVS) {
  const out = join(DIR, env.key);
  mkdirSync(out, { recursive: true });
  for (const file of readdirSync(DIR).filter((f) => /^WF\d.*\.json$/.test(f))) {
    const wf = JSON.parse(readFileSync(join(DIR, file), 'utf8')) as Workflow;
    wf.name = `[${env.label}] ${wf.name}`;
    wf.tags = [{ name: env.label }];
    for (const n of wf.nodes) {
      for (const c of Object.values(n.credentials ?? {})) {
        delete c.id;
        c.name = `${c.name} (${env.label})`;
      }
      if (n.webhookId) n.webhookId = uuidFor(`${env.key}:${file}:${n.name}`);
      const p = n.parameters ?? {};
      if (typeof p.path === 'string' && env.pathPrefix) p.path = env.pathPrefix + p.path;
      if (typeof p.jsCode === 'string') {
        p.jsCode = p.jsCode
          .replace(
            'https://YOUR-PROJECT.supabase.co',
            `https://YOUR-${env.label.toUpperCase()}-PROJECT.supabase.co`,
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
