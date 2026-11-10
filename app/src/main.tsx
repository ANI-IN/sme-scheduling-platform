import { StrictMode, lazy, Suspense } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Toaster } from 'sonner';
import { ThemeProvider, useTheme } from '@/lib/theme';
import './index.css';
import { AuthProvider, useAuth } from '@/lib/auth';
import { DomainProvider } from '@/lib/domain';
import { configMissing } from '@/lib/env';
import { ConfirmProvider } from '@/components/Confirm';
import { Layout } from '@/components/Layout';
import { Spinner } from '@/components/ui';
import { Login } from '@/pages/Login';

const NeedsAttention = lazy(() => import('@/pages/NeedsAttention'));
const Schedule = lazy(() => import('@/pages/Schedule'));
const Outreach = lazy(() => import('@/pages/Outreach'));
const Modules = lazy(() => import('@/pages/Modules'));
const Instructors = lazy(() => import('@/pages/Instructors'));
const Settings = lazy(() => import('@/pages/Settings'));
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
        docs/SETUP.md).
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
          <Route element={<Layout />}>
            <Route path="/attention" element={<NeedsAttention />} />
            <Route path="/schedule" element={<Schedule />} />
            <Route path="/outreach" element={<Outreach />} />
            <Route path="/modules" element={<Modules />} />
            <Route path="/instructors" element={<Instructors />} />
            <Route path="/settings" element={<Settings />} />
            <Route path="/history" element={<History />} />
            <Route path="*" element={<Navigate to="/attention" replace />} />
          </Route>
        </Routes>
      </Suspense>
    </DomainProvider>
  );
}

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
