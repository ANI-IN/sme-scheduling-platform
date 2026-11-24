// Live updates (Release 3, C15). One Realtime channel for the whole app listens to the tables people look at.
// A change marks only the cached lists that read that table as out of date, so only those load again, and a burst
// of changes (the automation often writes many rows at once) causes one reload, about 300 ms after the last one.
// When Realtime is not connected the open page checks again every 60 seconds instead. A hidden tab never loads
// anything: it catches up when it is shown again.
//
// Saves use the same map: refresh(qc, 'instructor') after saving an instructor marks the lists that show
// instructors, without waiting for them to load again.
import { useEffect } from 'react';
import { useQueryClient, type QueryClient, type QueryKey } from '@tanstack/react-query';
import { supabase } from './supabase';
import { poke } from './rpc';

/** The tables in the supabase_realtime publication (migration 20261123000034_live_updates.sql). */
export const LIVE_TABLES = [
  'module_week',
  'class_session',
  'request',
  'booking',
  'attention_item',
  'help_request',
  'message',
  'instructor',
  'team_member',
  'module',
  'cohort',
  'domain',
  'discord_server',
  'discord_channel',
  'action_queue',
  'time_proposal',
  'cohort_break',
  'cohort_holiday',
  'history_event',
  'system_state',
  'app_config',
  'standard_schedule',
] as const;
export type LiveTable = (typeof LIVE_TABLES)[number];

/** Cached lists of tables that are not live: a save names them itself. */
export type OtherList =
  | 'setting'
  | 'holiday'
  | 'class_type'
  | 'domain_team'
  | 'module_operations'
  | 'message_template'
  | 'beta_access'
  | 'checklist_item'
  | 'app_error'
  | 'discord_server_domain'
  | 'usage';

type Prefix = readonly string[];

/** What every setup change can move: the setup steps on Home. */
const SETUP: Prefix[] = [['domain', 'setup-status'], ['get-started']];

/**
 * For each live table, the cached lists that read it, by the start of their query key (the keys are in
 * lib/data.ts and the pages). A list that joins several tables is under each of them.
 */
export const READERS: Record<LiveTable, readonly Prefix[]> = {
  module_week: [['module_week'], ['request'], ['booking'], ['checklist_item'], ...SETUP],
  class_session: [['module_week'], ['request'], ['booking'], ['checklist_item']],
  request: [['module_week'], ['request']],
  booking: [['module_week'], ['booking'], ['request']],
  attention_item: [['attention_item']],
  help_request: [['help_request'], ['module_week'], ['attention_item']],
  message: [['message'], ['history_event', 'timeline'], ['help_request']],
  instructor: [['instructor'], ['request'], ['booking'], ...SETUP],
  team_member: [['team_member'], ...SETUP],
  module: [['module'], ['module_week'], ['request'], ['booking'], ...SETUP],
  cohort: [['cohort'], ['module_week'], ['module', 'names'], ...SETUP],
  domain: [['domain'], ['get-started']],
  discord_server: [['discord_server'], ['discord_server_domain'], ['discord_channel'], ...SETUP],
  discord_channel: [['discord_channel']],
  action_queue: [['module_week'], ['usage']],
  time_proposal: [['module_week']],
  cohort_break: [['cohort_break'], ['module_week'], ['cohort']],
  cohort_holiday: [['cohort_holiday'], ['module_week']],
  history_event: [['history_event']],
  system_state: [['system_state']],
  app_config: [['system_state']],
  standard_schedule: [['standard_schedule'], ['module_week', 'schedule_status']],
};

const isLive = (x: string): x is LiveTable => x in READERS;

function prefixesFor(what: readonly (LiveTable | OtherList)[]): Prefix[] {
  return what.flatMap((w) => (isLive(w) ? READERS[w] : [[w] as Prefix]));
}

const startsWith = (key: QueryKey, p: Prefix) => p.every((part, i) => key[i] === part);

/**
 * After a save: mark the lists that read these tables (or these other lists) out of date. The lists on screen load
 * again in the background; nothing waits for them, so a drawer can close and "Saved" can show at once.
 */
export function refresh(qc: QueryClient, ...what: (LiveTable | OtherList)[]): void {
  void refreshNow(qc, ...what);
}

/**
 * The same as refresh, but finishes when the lists have loaded again. A save that shows its result as it runs (a
 * faded chip) waits for this, so the result does not disappear between the save and the reload.
 */
export function refreshNow(qc: QueryClient, ...what: (LiveTable | OtherList)[]): Promise<void> {
  const prefixes = prefixesFor(what);
  return qc.invalidateQueries({
    predicate: (q) => prefixes.some((p) => startsWith(q.queryKey, p)),
  });
}

/** After a change to class weeks: the weeks, their classes, requests, bookings, tasks and timelines. */
export function refreshClasses(qc: QueryClient): void {
  refresh(
    qc,
    'module_week',
    'class_session',
    'request',
    'booking',
    'attention_item',
    'help_request',
    'time_proposal',
    'cohort_break',
    'cohort_holiday',
    'history_event',
    'message',
  );
}

/**
 * Ask n8n to deliver queued messages now, without waiting for it. When it answers, the lists its work changes load
 * again (Realtime usually shows them sooner).
 */
export function deliverNow(qc: QueryClient): void {
  void poke().then(() =>
    refresh(qc, 'message', 'request', 'module_week', 'attention_item', 'history_event'),
  );
}

/** Previews worked out before a confirmation: they stay as the person saw them. */
const isPreview = (key: QueryKey) => typeof key[0] === 'string' && key[0].endsWith('_preview');

/**
 * After a change that reaches almost everything (deleting a domain, pausing all messages, a reset on Testing):
 * every list except the previews, again without waiting.
 */
export function refreshAll(qc: QueryClient): void {
  void qc.invalidateQueries({ predicate: (q) => !isPreview(q.queryKey) });
}

const DEBOUNCE_MS = 300;
/** Even while changes keep coming, the screen catches up at least this often. */
const MAX_WAIT_MS = 2000;
/** How often an open page checks for news while Realtime is not connected. */
export const FALLBACK_POLL_MS = 60_000;

const hidden = () => typeof document !== 'undefined' && document.visibilityState === 'hidden';

/** Listen to every live table once, for the whole app. Used once, in the app shell. */
export function useLiveUpdates(): void {
  const qc = useQueryClient();
  useEffect(() => {
    const pending = new Set<LiveTable>();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let firstAt = 0;
    let poll: ReturnType<typeof setInterval> | undefined;
    let connected = false;
    let everConnected = false;
    let missed = false;
    let disposed = false;
    let catchUp = false;

    const flush = () => {
      timer = undefined;
      firstAt = 0;
      // A hidden tab keeps what changed and loads it when it is shown again.
      if (hidden() || pending.size === 0) return;
      const tables = [...pending];
      pending.clear();
      refresh(qc, ...tables);
    };
    const changed = (t: LiveTable) => {
      pending.add(t);
      const now = Date.now();
      if (!firstAt) firstAt = now;
      if (timer) clearTimeout(timer);
      timer = setTimeout(flush, now - firstAt >= MAX_WAIT_MS ? 0 : DEBOUNCE_MS);
    };
    const everything = () => LIVE_TABLES.forEach((t) => pending.add(t));
    const loadedBeforeListening = () =>
      qc
        .getQueryCache()
        .getAll()
        .some((q) => q.state.dataUpdatedAt > 0 && !isPreview(q.queryKey));

    const startPolling = () => {
      if (poll) return;
      poll = setInterval(() => {
        if (hidden()) return;
        everything();
        flush();
        if (connected && catchUp) {
          catchUp = false;
          stopPolling();
        }
      }, FALLBACK_POLL_MS);
    };
    const stopPolling = () => {
      if (poll) clearInterval(poll);
      poll = undefined;
    };
    const onVisible = () => {
      if (hidden()) return;
      // Changes missed while the connection was down are not sent again, so look at everything once.
      if (!connected) everything();
      flush();
    };
    document.addEventListener('visibilitychange', onVisible);

    // A unique name per mount: removing a channel is asynchronous, and reusing the same name before it
    // is gone makes Supabase refuse new listeners ("cannot add postgres_changes callbacks").
    const ch = supabase.channel(`live-${Math.random().toString(36).slice(2)}`);
    for (const table of LIVE_TABLES) {
      ch.on('postgres_changes', { event: '*', schema: 'public', table }, () => changed(table));
    }
    ch.subscribe((status) => {
      if (disposed) return;
      if (status === 'SUBSCRIBED') {
        connected = true;
        // The first time: anything the page read before we were listening may have changed in between (found by
        // the full run of 24 November: a change made just after a page loaded never showed). The 60 second check
        // then runs once more before it stops, so such a change shows within a minute, without reading at once.
        if (!everConnected && loadedBeforeListening()) catchUp = true;
        else stopPolling();
        // Back after a break: changes made meanwhile were not sent, so look at everything once.
        if (everConnected && missed) {
          missed = false;
          everything();
          flush();
        }
        everConnected = true;
      } else {
        // CHANNEL_ERROR, TIMED_OUT or CLOSED: check every 60 seconds until it is back.
        connected = false;
        missed = true;
        startPolling();
      }
    });
    // Until Realtime answers, the page checks now and then, as when it is not connected.
    startPolling();

    return () => {
      disposed = true;
      if (timer) clearTimeout(timer);
      stopPolling();
      document.removeEventListener('visibilitychange', onVisible);
      void supabase.removeChannel(ch);
    };
  }, [qc]);
}
