import { useEffect } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/lib/auth';
import { useDomain } from '@/lib/domain';
import { useSystem } from '@/lib/data';
import { cn, Select } from './ui';

const tabs = [
  { to: '/attention', label: 'Needs Attention' },
  { to: '/schedule', label: 'Schedule' },
  { to: '/outreach', label: 'Outreach' },
  { to: '/modules', label: 'Modules' },
  { to: '/instructors', label: 'Instructors' },
  { to: '/settings', label: 'Settings' },
  { to: '/history', label: 'History' },
];

const liveTables = [
  'attention_item',
  'module_week',
  'request',
  'booking',
  'help_request',
  'class_session',
  'system_state',
];

export function Layout() {
  const { session, signOut } = useAuth();
  const { domain, domains, setDomainId } = useDomain();
  const system = useSystem();
  const qc = useQueryClient();

  // Realtime: anything n8n or a teammate changes refreshes the open screens.
  useEffect(() => {
    const ch = supabase.channel('live');
    for (const table of liveTables) {
      ch.on('postgres_changes', { event: '*', schema: 'public', table }, () => {
        void qc.invalidateQueries();
      });
    }
    ch.subscribe();
    return () => {
      void supabase.removeChannel(ch);
    };
  }, [qc]);

  const urgent = useQuery({
    queryKey: ['attention_item', 'urgent-count'],
    queryFn: async () => {
      const { count } = await supabase
        .from('attention_item')
        .select('id', { count: 'exact', head: true })
        .neq('status', 'Done')
        .eq('severity', 'Urgent');
      return count ?? 0;
    },
  });

  const killed = system.data && !system.data.state.outreach_enabled;

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3 px-4 py-2">
          <span className="font-semibold text-slate-900">SME Scheduling</span>
          <Select
            aria-label="Domain"
            className="w-48"
            value={domain?.id ?? ''}
            onChange={(e) => setDomainId(e.target.value)}
          >
            {domains.length === 0 && <option value="">No domains yet</option>}
            {domains.map((d) => (
              <option key={d.id} value={d.id}>
                {d.name} ({d.status})
              </option>
            ))}
          </Select>
          <div className="ml-auto flex items-center gap-3 text-sm text-slate-600">
            <span className="hidden sm:inline">{session?.user.email}</span>
            <button className="text-blue-700 hover:underline" onClick={() => void signOut()}>
              Sign out
            </button>
          </div>
        </div>
        <nav className="mx-auto flex max-w-7xl gap-1 overflow-x-auto px-4">
          {tabs.map((t) => (
            <NavLink
              key={t.to}
              to={t.to}
              className={({ isActive }) =>
                cn(
                  'border-b-2 px-3 py-2 text-sm font-medium whitespace-nowrap',
                  isActive
                    ? 'border-blue-600 text-blue-700'
                    : 'border-transparent text-slate-600 hover:text-slate-900',
                )
              }
            >
              {t.label}
              {t.to === '/attention' && (urgent.data ?? 0) > 0 && (
                <span className="ml-1.5 rounded-full bg-red-600 px-1.5 text-xs text-white">
                  {urgent.data}
                </span>
              )}
            </NavLink>
          ))}
        </nav>
      </header>
      {(domain?.status === 'Test' ||
        (domain?.status === 'Paused' && domain.paused_from === 'Test')) && (
        <div className="bg-amber-400 px-4 py-1.5 text-center text-sm font-semibold text-amber-950">
          TEST MODE — {domain.name} messages go to the test Discord channel and test email only. No
          real instructor is contacted.
          {domain.test_clock_at && ' Test clock is set (Settings → Test mode).'}
        </div>
      )}
      {domain?.status === 'Paused' && (
        <div className="bg-slate-700 px-4 py-1.5 text-center text-sm text-white">
          {domain.name} is paused: no instructor messages, requests don’t move on, check-ins are
          paused.
        </div>
      )}
      {killed && (
        <div className="bg-red-700 px-4 py-1.5 text-center text-sm font-semibold text-white">
          Kill switch is ON — all instructor messages are paused everywhere. Team alerts continue.
          (Settings → System)
        </div>
      )}
      <main className="mx-auto max-w-7xl px-4 py-5">
        <Outlet />
      </main>
    </div>
  );
}
