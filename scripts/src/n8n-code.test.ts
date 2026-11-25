// The code steps of the n8n workflows, run with made up inputs (review batches 5 and 6).
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

type Json = Record<string, unknown>;
type Node = {
  name: string;
  type: string;
  parameters: Record<string, string>;
  retryOnFail?: boolean;
};
type Flow = {
  nodes: Node[];
  connections: Record<string, { main: ({ node: string }[] | null)[] }>;
};
const flow = (name: string) =>
  JSON.parse(readFileSync(join(import.meta.dirname, '..', '..', 'n8n', name), 'utf8')) as Flow;
const wf4 = flow('WF4-action-runner.json');
const wf5 = flow('WF5-error-handler.json');
const node = (f: Flow, name: string) => {
  const n = f.nodes.find((x) => x.name === name);
  assert.ok(n, `node ${name}`);
  return n;
};
const items = (list: Json[]) => ({
  all: () => list.map((json, i) => ({ json, pairedItem: { item: i } })),
  first: () => ({ json: list[0] }),
});
/** Run a code step: $input holds `input`, $('Name') holds the items given for that name. */
function run(name: string, input: Json[], others: Record<string, Json[]> = {}, f = wf4) {
  const body = node(f, name).parameters.jsCode!;
  const fn = new Function('$input', '$', body) as (a: unknown, b: unknown) => { json: Json }[];
  return fn(items(input), (n: string) => items(others[n] ?? [])).map((x) => x.json ?? x) as Json[];
}

test('only rows taken for sending go on (R2)', () => {
  const rows = [
    { id: '1', channel: 'Email', status: 'Sending' },
    { id: '2', channel: 'Email', status: 'Cancelled' },
  ];
  const kept = new Function('$input', node(wf4, 'Keep claimed rows').parameters.jsCode!)(
    items(rows),
  ) as { json: Json }[];
  assert.deepEqual(
    kept.map((x) => x.json.id),
    ['1'],
  );
});

test('a Discord answer carries the claim and Discord’s retry time; a refused login is not permanent (R4, R6, R16)', () => {
  const prep = { 'Prepare Discord': [{ message_id: 'm', claimed_at: 't1', targetChannelId: 'c' }] };
  const [limited] = run('Discord result', [{ statusCode: 429, body: { retry_after: 2.5 } }], prep);
  assert.equal(limited!.p_retry_after, 3);
  assert.equal(limited!.p_claimed_at, 't1');
  assert.equal(limited!.p_permanent, false);
  const [login] = run(
    'Discord result',
    [{ statusCode: 401, body: { message: 'Unauthorized' } }],
    prep,
  );
  assert.equal(login!.p_permanent, false);
  const [gone] = run(
    'Discord result',
    [{ statusCode: 404, body: { message: 'Unknown Channel' } }],
    prep,
  );
  assert.equal(gone!.p_permanent, true);
});

test('an expired Gmail login is temporary (R16)', () => {
  const [r] = run('Email result', [{ error: { message: 'invalid_grant' } }], {
    'Prepare email': [{ message_id: 'm', claimed_at: 't2', to: 'a@example.com' }],
  });
  assert.equal(r!.p_permanent, false);
  assert.equal(r!.p_claimed_at, 't2');
});

test('a reply carries its channel, and a message with no readable text is recorded (R8, R15)', () => {
  const watch = {
    'Get watchlist': [{ channel_id: 'c9', discord_user_id: 'u1', last_message_id: '1' }],
  };
  const body = [
    {
      id: '5',
      author: { id: 'u1' },
      content: 'Can we start later?',
      timestamp: new Date().toISOString(),
    },
    { id: '6', author: { id: 'u1' }, content: '', timestamp: new Date().toISOString() },
    { id: '7', author: { id: 'other' }, content: 'hi', timestamp: new Date().toISOString() },
  ];
  const out = run('Pick instructor replies', [{ statusCode: 200, body }], watch);
  assert.equal(out.length, 2);
  assert.equal((out[0]!.args as Json).p_channel_id, 'c9');
  assert.match(String((out[1]!.args as Json).p_body), /no readable text/);
});

test('channels that cannot be read are reported once (R15)', () => {
  const watch = { 'Get watchlist': [{ channel_id: 'a' }, { channel_id: 'b' }] };
  const out = run(
    'Pick read problems',
    [
      { statusCode: 403, body: {} },
      { statusCode: 200, body: [] },
    ],
    watch,
  );
  assert.equal(out.length, 1);
  assert.match(String(out[0]!.error), /channel a: 403/);
  assert.equal(run('Pick read problems', [{ statusCode: 200, body: [] }], watch).length, 0);
});

test('automatic replies are marked, ordinary replies are not (R19)', () => {
  const sys = 'scheduling-mailbox+scheduling@yourcompany.com';
  const mail = (id: string, subject: string, headers: Json) => ({
    id,
    from: { text: 'x@example.org' },
    to: { text: sys },
    subject,
    text: 'hello',
    headers: { to: sys, ...headers },
  });
  const out = run('Classify emails', [
    mail('1', 'Re: Can you teach?', {}),
    mail('2', 'Automatic reply: Can you teach?', {}),
    mail('3', 'Re: Can you teach?', { 'auto-submitted': 'auto-replied' }),
    mail('4', 'News', { precedence: 'bulk' }),
  ]);
  assert.deepEqual(
    out.map((x) => (x.args as Json).p_automatic),
    [false, true, true, true],
  );
});

test('postmaster bounces are read and labelling failures are logged (R18)', () => {
  const q = (node(wf4, 'Get system replies').parameters as unknown as { filters: { q: string } })
    .filters.q;
  assert.match(q, /from:postmaster/);
  assert.equal(wf4.connections['Label as processed']!.main[1]![0]!.node, 'Log reading problem');
});

test('claims are not repeated by a retry (R28)', () => {
  assert.ok(!node(wf4, 'Get queued actions').retryOnFail);
  assert.ok(!node(wf4, 'Get Discord work').retryOnFail);
});

test('the safety run is hourly and nothing else calls WF4 (R6)', () => {
  assert.deepEqual(node(wf4, 'Every hour').parameters, {
    rule: { interval: [{ field: 'hours', hoursInterval: 1 }] },
  });
  for (const f of ['WF2-response-handler.json', 'WF3-daily-jobs.json', 'WF5-error-handler.json'])
    assert.ok(!flow(f).nodes.some((n) => n.name === 'Poke WF4'), f);
});

test('WF5 can post to the admin channel when the database is down (R17)', () => {
  assert.match(node(wf5, 'Config').parameters.jsCode!, /adminChannelId/);
  assert.match(
    node(wf5, 'Post to admin channel').parameters.url!,
    /\|\| \$\('Config'\)\.first\(\)\.json\.adminChannelId/,
  );
});
