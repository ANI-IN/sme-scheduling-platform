// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';

const reported: string[] = [];
vi.mock('@/lib/errorLog', () => ({
  reportError: (_e: unknown, context?: string) => reported.push(context ?? ''),
}));
const { PageErrorBoundary } = await import('./PageErrorBoundary');

let broken = true;
function Page() {
  if (broken) throw new Error('Cannot read properties of undefined');
  return <p>The page works</p>;
}

afterEach(() => {
  cleanup();
  reported.length = 0;
  broken = true;
});

describe('PageErrorBoundary', () => {
  it('shows Try again instead of a blank app, logs the error, and shows the page again', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    render(
      <PageErrorBoundary>
        <Page />
      </PageErrorBoundary>,
    );
    expect(screen.getByRole('alert')).toHaveTextContent('This page could not be shown');
    expect(reported).toEqual(['Page could not be shown']);
    broken = false;
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(screen.getByText('The page works')).toBeInTheDocument();
  });

  it('asks to reload when the page belongs to an older version of the app', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    function Old(): never {
      throw new TypeError('Failed to fetch dynamically imported module: /assets/Home-abc.js');
    }
    render(
      <PageErrorBoundary>
        <Old />
      </PageErrorBoundary>,
    );
    expect(screen.getByRole('alert')).toHaveTextContent('A new version of the app is out.');
    expect(screen.getByRole('button', { name: 'Reload' })).toBeInTheDocument();
  });
});
