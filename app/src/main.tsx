import { StrictMode, lazy, Suspense } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Toaster } from 'sonner';
import { ThemeProvider, useTheme } from '@/lib/theme';
import './index.css';
import { AuthProvider, useAuth } from '@/lib/auth';
import { installGlobalErrorReporting } from '@/lib/errorLog';
import { DomainProvider } from '@/lib/domain';
import { configMissing } from '@/lib/env';
import { ConfirmProvider } from '@/components/Confirm';
import { AppShell } from '@/components/AppShell';
import { Spinner } from '@/components/ui';
import { Login } from '@/pages/Login';

const Home = lazy(() => import('@/pages/Home'));
const Schedule = lazy(() => import('@/pages/Schedule'));
const Outreach = lazy(() => import('@/pages/Outreach'));
const Modules = lazy(() => import('@/pages/setup/Modules'));
const ModuleDetail = lazy(() => import('@/pages/setup/ModuleDetail'));
const ModuleNew = lazy(() => import('@/pages/setup/ModuleNew'));
const Instructors = lazy(() => import('@/pages/Instructors'));
const Team = lazy(() => import('@/pages/setup/Team'));
const Domains = lazy(() => import('@/pages/setup/Domains'));
const Automation = lazy(() => import('@/pages/settings/Automation'));
const Messages = lazy(() => import('@/pages/settings/Messages'));
const Help = lazy(() => import('@/pages/Help'));
const Testing = lazy(() => import('@/pages/settings/Testing'));
const Connections = lazy(() => import('@/pages/settings/Connections'));
const History = lazy(() => import('@/pages/History'));

function ThemedToaster() {
  const { resolved } = useTheme();
  return <Toaster theme={resolved} richColors closeButton position="top-right" />;
}

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 10_000, refetchOnWindowFocus: true, retry: 1 } },
});

function Gate() {
  const { session, loading } = useAuth();
  if (configMissing) {
    return (
      <div className="p-8 text-sm">
        The app is not configured yet: set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY (see
        docs/SETUP_GUIDE.md).
      </div>
    );
  }
  if (loading)
    return (
      <div className="flex min-h-screen items-center justify-center">
        <Spinner />
      </div>
    );
  if (!session) return <Login />;
  return (
    <DomainProvider>
      <Suspense
        fallback={
          <div className="p-8">
            <Spinner />
          </div>
        }
      >
        <Routes>
          <Route element={<AppShell />}>
            <Route index element={<Home />} />
            <Route path="/classes" element={<Schedule />} />
            <Route path="/requests" element={<Outreach />} />
            <Route path="/setup/modules" element={<Modules />} />
            <Route path="/setup/modules/new" element={<ModuleNew />} />
            <Route path="/setup/modules/:id" element={<ModuleDetail />} />
            <Route path="/setup/instructors" element={<Instructors />} />
            <Route path="/setup/team" element={<Team />} />
            <Route path="/setup/domains" element={<Domains />} />
            <Route path="/settings" element={<Navigate to="/settings/automation" replace />} />
            <Route path="/settings/automation" element={<Automation />} />
            <Route path="/settings/messages" element={<Messages />} />
            <Route path="/help" element={<Help />} />
            <Route path="/help/:slug" element={<Help />} />
            <Route path="/settings/testing" element={<Testing />} />
            <Route path="/settings/connections" element={<Connections />} />
            <Route path="/activity" element={<History />} />
            {/* Old addresses keep working. */}
            <Route path="/attention" element={<Navigate to="/" replace />} />
            <Route path="/schedule" element={<Navigate to="/classes" replace />} />
            <Route path="/outreach" element={<Navigate to="/requests" replace />} />
            <Route path="/modules" element={<Navigate to="/setup/modules" replace />} />
            <Route path="/instructors" element={<Navigate to="/setup/instructors" replace />} />
            <Route path="/history" element={<Navigate to="/activity" replace />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      </Suspense>
    </DomainProvider>
  );
}

installGlobalErrorReporting();

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <AuthProvider>
          <ConfirmProvider>
            <BrowserRouter>
              <Gate />
            </BrowserRouter>
            <ThemedToaster />
          </ConfirmProvider>
        </AuthProvider>
      </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
);
