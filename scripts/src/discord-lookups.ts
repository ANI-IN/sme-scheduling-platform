// Does the Discord checks the app asks for (list the bot's servers, check a domain's server and its
// channels, find a person by username), the same way the n8n workflow WF6 does. Use it on your own
// computer, or to check a real bot before n8n is set up.
//
//   DISCORD_BOT_TOKEN=... npm run discord -w scripts            (reads DATABASE_URL, default local)
//   npm run discord:sandbox -w scripts                           (reads .env.sandbox)
//
// The token is never stored or printed. The database decides what each answer means
// (record_discord_result), so this script only makes the calls and passes the raw answers on.
import pg from 'pg';

export type Lookup =
  | { action_id: string; action: 'discord_servers' }
  | {
      action_id: string;
      action: 'discord_server';
      server_id: string | null;
      bot_user_id?: string | null;
    }
  | { action_id: string; action: 'discord_member'; username: string | null; servers: string[] };

type Call = { status: number; body?: unknown };
type Get = (path: string) => Promise<Call>;

/** One Discord API call; network problems become status 0 so the database can explain them. */
export function discordGet(token: string, fetchImpl: typeof fetch = fetch): Get {
  return async (path) => {
    try {
      const r = await fetchImpl(`https://discord.com/api/v10${path}`, {
        headers: { Authorization: `Bot ${token}`, 'User-Agent': 'SME Scheduling (scheduling bot)' },
      });
      const text = await r.text();
      let body: unknown = undefined;
      try {
        body = text ? JSON.parse(text) : undefined;
      } catch {
        body = undefined;
      }
      return { status: r.status, body: r.ok ? body : undefined };
    } catch {
      return { status: 0 };
    }
  };
}

/** The raw answers for one piece of work, in the shape record_discord_result reads. */
export async function lookup(item: Lookup, get: Get): Promise<Record<string, unknown>> {
  if (item.action === 'discord_servers')
    return { guilds: await get('/users/@me/guilds'), me: await get('/users/@me') };
  if (item.action === 'discord_server') {
    if (!item.server_id) return { guild: { status: 404 } };
    const guild = await get(`/guilds/${item.server_id}`);
    if (guild.status !== 200) return { guild };
    const channels = await get(`/guilds/${item.server_id}/channels`);
    // A tiny member search shows whether Server Members Intent is on.
    const members = await get(`/guilds/${item.server_id}/members/search?query=a&limit=1`);
    // The server's roles and the bot's own roles: the database works out where the bot may post.
    const roles = await get(`/guilds/${item.server_id}/roles`);
    const me = await get('/users/@me');
    const botId = item.bot_user_id ?? (me.body as { id?: string } | undefined)?.id;
    const bot = botId ? await get(`/guilds/${item.server_id}/members/${botId}`) : { status: 0 };
    return { guild, channels, members: { status: members.status }, roles, me, bot };
  }
  const searches = [];
  for (const server_id of item.servers ?? []) {
    if (!item.username) break;
    const r = await get(
      `/guilds/${server_id}/members/search?query=${encodeURIComponent(item.username)}&limit=1000`,
    );
    searches.push({ server_id, status: r.status, body: r.body ?? [] });
    const found = Array.isArray(r.body)
      ? (r.body as { user?: { username?: string } }[]).some(
          (m) => m.user?.username?.toLowerCase() === item.username,
        )
      : false;
    if (found) break;
  }
  return { searches };
}

async function main() {
  const token = process.env.DISCORD_BOT_TOKEN ?? process.env.SANDBOX_DISCORD_BOT_TOKEN;
  if (!token) {
    console.error(
      'Set DISCORD_BOT_TOKEN (the bot token from the Discord Developer Portal) in your environment first. It is never saved.',
    );
    process.exit(1);
  }
  const db = new pg.Client({
    connectionString:
      process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres',
  });
  await db.connect();
  try {
    const { rows } = await db.query<{ v: Lookup[] }>('select public.next_discord_lookups(50) v');
    const work = rows[0]?.v ?? [];
    if (work.length === 0) console.log('Nothing to check. Press a Check button in the app first.');
    const get = discordGet(token);
    for (const item of work) {
      const result = await lookup(item, get);
      const { rows: r } = await db.query<{ v: { status?: string; problem?: string } }>(
        'select public.record_discord_result($1, $2) v',
        [item.action_id, JSON.stringify(result)],
      );
      const v = r[0]?.v ?? {};
      console.log(`${item.action}: ${v.problem ?? v.status ?? 'done'}`);
    }
  } finally {
    await db.end();
  }
}

if (process.argv[1]?.endsWith('discord-lookups.ts')) await main();
