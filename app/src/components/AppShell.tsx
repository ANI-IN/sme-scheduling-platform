import { useDiscordNames } from '@/lib/useDiscordNames';
import { useLiveUpdates } from '@/lib/live';
import { useState, type ReactNode } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Dialog as D, DropdownMenu as DM } from 'radix-ui';
import {
  Activity,
  BookOpen,
  CalendarDays,
  LayoutGrid,
  Check,
  ChevronDown,
  ChevronsLeft,
  ChevronsRight,
  Cog,
  FlaskConical,
  Globe2,
  Home,
  LogOut,
  Menu,
  PlugZap,
  Send,
  UserRound,
  Users,
  X,
  LifeBuoy,
  ListOrdered,
  MessageSquareText,
  OctagonPause,
  ShieldCheck,
} from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/lib/auth';
import { DiscordPrompt } from './DiscordPrompt';
import { usePauseAll } from './PauseAll';
import { confirmLeave } from '@/lib/unsaved';
import { useDomain } from '@/lib/domain';
import { LIVE_CHECK_MS, useMe, type Domain } from '@/lib/data';
import { fmtPT } from '@/lib/time';
import { Badge, Button, cn, type Tone } from './ui';
import { ThemeMenuChoice } from './ThemeSwitch';
import { PageErrorBoundary } from './PageErrorBoundary';

/** adminOnly: shown to admins only (decision 276). */
type Item = { to: string; label: string; icon: typeof Home; end?: boolean; adminOnly?: boolean };
const groups: { label?: string; items: Item[] }[] = [
  { items: [{ to: '/', label: 'Home', icon: Home, end: true }] },
  {
    label: 'Classes',
    items: [
      { to: '/board', label: 'Schedule board', icon: LayoutGrid },
      { to: '/classes', label: 'Upcoming classes', icon: CalendarDays },
      { to: '/requests', label: 'Instructor requests', icon: Send },
    ],
  },
  {
    label: 'Setup',
    items: [
      { to: '/setup/modules', label: 'Modules', icon: BookOpen },
      { to: '/setup/standards', label: 'Standard schedules', icon: ListOrdered },
      { to: '/setup/instructors', label: 'Instructors', icon: UserRound },
      { to: '/setup/team', label: 'Team', icon: Users },
      { to: '/setup/domains', label: 'Domains', icon: Globe2 },
    ],
  },
  {
    label: 'Settings',
    items: [
      { to: '/settings/automation', label: 'Automation', icon: Cog },
      { to: '/settings/messages', label: 'Message templates', icon: MessageSquareText },
      { to: '/settings/testing', label: 'Testing', icon: FlaskConical },
      { to: '/settings/connections', label: 'Connections', icon: PlugZap },
      { to: '/settings/admin', label: 'Admin', icon: ShieldCheck, adminOnly: true },
    ],
  },
  {
    items: [
      { to: '/activity', label: 'Activity history', icon: Activity },
      { to: '/help', label: 'Help', icon: LifeBuoy },
    ],
  },
];

export const statusLabel: Record<string, string> = {
  Draft: 'Draft',
  Test: 'Testing',
  Live: 'Live',
  Paused: 'Paused',
};
export const statusTone: Record<string, Tone> = {
  Draft: 'neutral',
  Test: 'warning',
  Live: 'success',
  Paused: 'accent',
};

export const isTesting = (d: Domain | null | undefined) =>
  !!d && (d.status === 'Test' || (d.status === 'Paused' && d.paused_from === 'Test'));

const COLLAPSE_KEY = 'ik-sidebar-collapsed';

export function AppShell() {
  useDiscordNames();
  // Live updates: anything the automation or a teammate changes refreshes the open screens (lib/live.ts).
  useLiveUpdates();
  const location = useLocation();
  const [mobileOpen, setMobileOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(() => {
    try {
      return localStorage.getItem(COLLAPSE_KEY) === '1';
    } catch {
      return false;
    }
  });

  // Close the mobile menu after navigating.
  const [lastPath, setLastPath] = useState(location.pathname);
  if (lastPath !== location.pathname) {
    setLastPath(location.pathname);
    if (mobileOpen) setMobileOpen(false);
  }

  const toggle = () => {
    setCollapsed((c) => {
      try {
        localStorage.setItem(COLLAPSE_KEY, c ? '0' : '1');
      } catch {
        // per-viewer convenience only
      }
      return !c;
    });
  };

  return (
    <div className="flex min-h-screen bg-background text-foreground">
      <aside
        className={cn(
          'sticky top-0 hidden h-screen shrink-0 flex-col border-r border-border bg-sidebar md:flex',
          collapsed ? 'w-16' : 'w-64',
        )}
      >
        <Sidebar collapsed={collapsed} onToggle={toggle} />
      </aside>
      <D.Root open={mobileOpen} onOpenChange={setMobileOpen}>
        <D.Portal>
          <D.Overlay className="fixed inset-0 z-40 bg-overlay md:hidden" />
          <D.Content className="fixed inset-y-0 left-0 z-50 flex w-72 flex-col border-r border-border bg-sidebar shadow-lg md:hidden">
            <D.Title className="sr-only">Menu</D.Title>
            <D.Description className="sr-only">Pages of SME Scheduling</D.Description>
            <D.Close
              className="absolute top-3 right-3 rounded-md p-1 text-muted-foreground hover:bg-muted"
              aria-label="Close menu"
            >
              <X className="h-4 w-4" />
            </D.Close>
            <Sidebar collapsed={false} />
          </D.Content>
        </D.Portal>
      </D.Root>
      <div className="flex min-w-0 flex-1 flex-col">
        <div className="sticky top-0 z-30 flex items-center gap-2 border-b border-border bg-sidebar px-3 py-2 md:hidden">
          <button
            className="rounded-md p-1.5 hover:bg-muted"
            aria-label="Open menu"
            onClick={() => setMobileOpen(true)}
          >
            <Menu className="h-5 w-5" />
          </button>
          <span className="font-semibold">SME Scheduling</span>
          <EnvironmentLabel />
        </div>
        <Banners />
        <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-6 md:px-8">
          <PageErrorBoundary key={location.pathname}>
            <Outlet />
          </PageErrorBoundary>
          <DiscordPrompt />
        </main>
      </div>
    </div>
  );
}

function Sidebar({ collapsed, onToggle }: { collapsed: boolean; onToggle?: () => void }) {
  const { domain } = useDomain();
  const isAdmin = !!useMe()?.is_admin;
  const urgent = useQuery({
    queryKey: ['attention_item', 'urgent-count', domain?.id],
    // Checks for new tasks every 30 seconds while open, in case a live update was missed.
    refetchInterval: LIVE_CHECK_MS,
    queryFn: async () => {
      let q = supabase
        .from('attention_item')
        .select('id', { count: 'exact', head: true })
        .neq('status', 'Done')
        .eq('severity', 'Urgent');
      if (domain) q = q.or(`domain_id.eq.${domain.id},domain_id.is.null`);
      const { count } = await q;
      return count ?? 0;
    },
  });
  return (
    <>
      <div
        className={cn('flex items-center gap-2 px-3 pt-4 pb-3', collapsed && 'justify-center px-2')}
      >
        {!collapsed && <span className="truncate text-base font-semibold">SME Scheduling</span>}
        {!collapsed && <EnvironmentLabel />}
        {onToggle && (
          <button
            onClick={onToggle}
            className={cn(
              'rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground',
              !collapsed && 'ml-auto',
            )}
            aria-label={collapsed ? 'Expand the sidebar' : 'Collapse the sidebar'}
            title={collapsed ? 'Expand the sidebar' : 'Collapse the sidebar'}
          >
            {collapsed ? (
              <ChevronsRight className="h-4 w-4" />
            ) : (
              <ChevronsLeft className="h-4 w-4" />
            )}
          </button>
        )}
      </div>
      <div className={cn('px-3 pb-3', collapsed && 'px-2')}>
        <DomainSwitcher collapsed={collapsed} />
      </div>
      <nav className="flex-1 space-y-4 overflow-y-auto px-2 py-2" aria-label="Main">
        {groups.map((g, i) => (
          <div key={i}>
            {g.label && !collapsed && (
              <div className="px-2 pb-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
                {g.label}
              </div>
            )}
            {g.label && collapsed && <div className="mx-2 mb-1 border-t border-border" />}
            <ul className="space-y-0.5">
              {g.items
                .filter((it) => !it.adminOnly || isAdmin)
                .map((it) => (
                  <li key={it.to}>
                    <NavLink
                      to={it.to}
                      end={it.end}
                      onClick={(e) => {
                        if (!confirmLeave()) e.preventDefault();
                      }}
                      title={collapsed ? it.label : undefined}
                      className={({ isActive }) =>
                        cn(
                          'flex items-center gap-2.5 rounded-md px-2 py-1.5 text-sm font-medium',
                          collapsed && 'justify-center',
                          isActive
                            ? 'bg-sidebar-active text-sidebar-active-foreground'
                            : 'text-sidebar-foreground hover:bg-muted hover:text-foreground',
                        )
                      }
                    >
                      <it.icon className="h-4 w-4 shrink-0" aria-hidden />
                      {!collapsed && <span className="truncate">{it.label}</span>}
                      {it.to === '/' && (urgent.data ?? 0) > 0 && (
                        <span
                          className={cn(
                            'rounded-full bg-destructive px-1.5 text-xs leading-5 text-destructive-foreground',
                            collapsed ? 'absolute ml-6 -mt-5' : 'ml-auto',
                          )}
                          title={`${urgent.data} urgent`}
                        >
                          {urgent.data}
                        </span>
                      )}
                    </NavLink>
                  </li>
                ))}
            </ul>
          </div>
        ))}
      </nav>
      <UserMenu collapsed={collapsed} />
    </>
  );
}

function DomainSwitcher({ collapsed }: { collapsed: boolean }) {
  const { domain, domains, setDomainId } = useDomain();
  return (
    <DM.Root modal={false}>
      <DM.Trigger
        className={cn(
          'flex w-full items-center gap-2 rounded-md border border-border bg-card px-2.5 py-2 text-left text-sm shadow-sm hover:bg-muted',
          collapsed && 'justify-center px-0',
        )}
      >
        <span className="sr-only">Choose a domain. </span>
        <Globe2 className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
        {!collapsed && (
          <>
            <span className="min-w-0 flex-1">
              <span className="block text-xs text-muted-foreground">Domain</span>
              <span className="block truncate font-medium">{domain?.name ?? 'No domains yet'}</span>
            </span>
            {domain && <Badge tone={statusTone[domain.status]}>{statusLabel[domain.status]}</Badge>}
            <ChevronDown className="h-4 w-4 text-muted-foreground" aria-hidden />
          </>
        )}
      </DM.Trigger>
      <DM.Portal>
        <DM.Content
          align="start"
          sideOffset={6}
          className="z-50 min-w-60 rounded-md border border-border bg-card p-1 text-card-foreground shadow-md"
        >
          {domains.map((d) => (
            <DM.Item
              key={d.id}
              // Review R10: unsaved edits belong to this domain, so ask before leaving them.
              onSelect={() => (d.id === domain?.id || confirmLeave()) && setDomainId(d.id)}
              className="flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-sm outline-none data-[highlighted]:bg-muted"
            >
              <Check
                className={cn('h-4 w-4', d.id === domain?.id ? 'opacity-100' : 'opacity-0')}
                aria-hidden
              />
              <span className="flex-1">{d.name}</span>
              <Badge tone={statusTone[d.status]}>{statusLabel[d.status]}</Badge>
            </DM.Item>
          ))}
          <DM.Separator className="my-1 h-px bg-border" />
          <DM.Item asChild>
            <Link
              to="/setup/domains"
              className="block rounded px-2 py-1.5 text-sm text-link outline-none data-[highlighted]:bg-muted"
            >
              Manage domains
            </Link>
          </DM.Item>
        </DM.Content>
      </DM.Portal>
    </DM.Root>
  );
}

function UserMenu({ collapsed }: { collapsed: boolean }) {
  const { session, account, signOut } = useAuth();
  const email = session?.user.email ?? '';
  const pause = usePauseAll();
  return (
    <div className={cn('border-t border-border p-3', collapsed && 'p-2')}>
      <DM.Root modal={false}>
        <DM.Trigger
          className={cn(
            'flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm hover:bg-muted',
            collapsed && 'justify-center px-0',
          )}
          title={email}
        >
          <span className="sr-only">Your account and theme: </span>
          <span
            className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary-soft text-xs font-semibold text-link"
            aria-hidden
          >
            {email.slice(0, 1).toUpperCase()}
          </span>
          {!collapsed && <span className="min-w-0 flex-1 truncate">{email}</span>}
        </DM.Trigger>
        <DM.Portal>
          <DM.Content
            side="top"
            align="start"
            sideOffset={6}
            className="z-50 w-72 rounded-md border border-border bg-card p-2 text-card-foreground shadow-md"
          >
            <div className="px-1 pb-2">
              {account?.member?.name && (
                <div className="text-sm font-medium">{account.member.name}</div>
              )}
              <div className="text-xs break-all text-muted-foreground" title={email}>
                {email}
              </div>
            </div>
            <DM.Label className="px-1 pb-1 text-xs font-medium">Theme</DM.Label>
            <ThemeMenuChoice />
            <DM.Separator className="my-1 h-px bg-border" />
            {pause.canChange && (
              <DM.Item
                onSelect={() => void pause.toggle()}
                className={cn(
                  'flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-sm outline-none data-[highlighted]:bg-muted',
                  pause.on && 'text-danger-strong',
                )}
              >
                <OctagonPause className="h-4 w-4" aria-hidden />
                {pause.on ? 'Pause all messages' : 'Turn messages back on'}
              </DM.Item>
            )}
            <DM.Item
              onSelect={() => void signOut()}
              className="flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-sm outline-none data-[highlighted]:bg-muted"
            >
              <LogOut className="h-4 w-4" aria-hidden /> Sign out
            </DM.Item>
          </DM.Content>
        </DM.Portal>
      </DM.Root>
    </div>
  );
}

function Bar({ tone, children }: { tone: 'warning' | 'neutral' | 'danger'; children: ReactNode }) {
  const cls = {
    warning: 'border-warning-strong/20 bg-warning-soft text-warning-strong',
    neutral: 'border-border bg-neutral-soft text-neutral-strong',
    danger: 'border-destructive/30 bg-danger-soft text-danger-strong',
  }[tone];
  return <div className={cn('border-b px-4 py-2 text-sm md:px-8', cls)}>{children}</div>;
}

function Banners() {
  const { domain } = useDomain();
  const pause = usePauseAll();
  const paused = pause.loaded && !pause.on;
  return (
    <>
      {isTesting(domain) && domain && (
        <Bar tone="warning">
          <strong className="font-semibold">Testing: </strong>
          messages for {domain.name} go only to your testing channel and testing email. No real
          instructor is contacted.
          {domain.test_clock_at && (
            <> The practice clock is set to {fmtPT(domain.test_clock_at)}.</>
          )}{' '}
          <Link to="/settings/testing" className="font-medium underline underline-offset-2">
            Open Testing
          </Link>
        </Bar>
      )}
      {domain?.status === 'Paused' && (
        <Bar tone="neutral">
          {domain.name} is paused: no messages go to instructors, requests wait, and reminders
          before class are on hold.{' '}
          <Link to="/setup/domains" className="font-medium underline underline-offset-2">
            Open Domains
          </Link>
        </Bar>
      )}
      {paused && (
        <Bar tone="danger">
          <span className="flex flex-wrap items-center gap-3">
            <span>
              <strong className="font-semibold">All messages to instructors are paused</strong> in
              every domain. Team alerts continue.
            </span>
            {pause.canChange && (
              <Button size="sm" onClick={() => void pause.toggle()}>
                Turn messages back on
              </Button>
            )}
          </span>
        </Bar>
      )}
    </>
  );
}

/**
 * Always visible outside Production, so nobody mistakes a copy that is not live for the real thing. The old
 * practice rules (environment "Sandbox", kept only as the rollback of the switch to Production) read "Not live";
 * no screen says Sandbox (Release 3, B4, decision 313).
 */
function EnvironmentLabel() {
  const { account } = useAuth();
  const env = account?.environment;
  if (!env || env === 'Production') return null;
  return (
    <span
      data-environment-label
      className={cn(
        'rounded px-1.5 py-0.5 text-[11px] font-bold tracking-wider uppercase',
        env === 'Sandbox'
          ? 'bg-accent-soft text-accent-strong ring-1 ring-accent-strong'
          : 'bg-neutral-soft text-neutral-strong',
      )}
      title={
        env === 'Sandbox'
          ? 'This copy is not live: messages only go to allowed test channels and mailboxes.'
          : 'This copy runs on a computer for development.'
      }
    >
      {env === 'Sandbox' ? 'Not live' : 'Development'}
    </span>
  );
}
