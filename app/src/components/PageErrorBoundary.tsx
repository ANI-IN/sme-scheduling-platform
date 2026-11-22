import { Component, type ReactNode } from 'react';
import { RotateCcw } from 'lucide-react';
import { reportError } from '@/lib/errorLog';
import { Button } from './ui';

/** A page that was built before a new version of the app went live can no longer load its parts. */
const isStaleBuild = (e: unknown) =>
  /dynamically imported module|Importing a module script failed|ChunkLoadError|Loading chunk/i.test(
    e instanceof Error ? e.message : String(e),
  );

/**
 * Release 3, M6: when one page breaks, only that page shows a short message with "Try again"; the menu and
 * everything else keep working. The error goes to the private error log (shown on Connections). Changing page
 * clears it, because the boundary is keyed by the address.
 */
export class PageErrorBoundary extends Component<
  { children: ReactNode },
  { error: unknown; failed: boolean }
> {
  state = { error: null as unknown, failed: false };

  static getDerivedStateFromError(error: unknown) {
    return { error, failed: true };
  }

  componentDidCatch(error: unknown) {
    reportError(error, 'Page could not be shown');
  }

  render() {
    if (!this.state.failed) return this.props.children;
    const stale = isStaleBuild(this.state.error);
    return (
      <div
        role="alert"
        className="mx-auto max-w-xl space-y-3 rounded-xl border border-border bg-card p-6"
      >
        <h1 className="text-lg font-semibold">This page could not be shown</h1>
        <p className="text-sm text-muted-foreground">
          {stale
            ? 'A new version of the app is out. Reload to get it; nothing you saved is lost.'
            : 'Something went wrong while showing this page. Nothing you saved is lost. Try again, or open another page from the menu. The problem was sent to the error log.'}
        </p>
        <Button
          onClick={() =>
            stale ? window.location.reload() : this.setState({ error: null, failed: false })
          }
        >
          <RotateCcw className="h-4 w-4" aria-hidden /> {stale ? 'Reload' : 'Try again'}
        </Button>
      </div>
    );
  }
}
