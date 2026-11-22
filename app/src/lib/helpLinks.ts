// Kept apart from the guides themselves so every page can link to Help without loading them.

/** Which guide the "?" link on each page opens. */
export function guideForPath(pathname: string): string {
  if (pathname === '/' || pathname.startsWith('/home')) return 'needs-your-attention';
  if (pathname.startsWith('/board')) return 'schedule-board';
  if (pathname.startsWith('/classes')) return 'planning-classes';
  if (pathname.startsWith('/requests')) return 'what-happens-automatically';
  if (pathname.startsWith('/setup/modules')) return 'setting-up-a-module';
  if (pathname.startsWith('/setup/standards')) return 'standard-schedules';
  if (pathname.startsWith('/setup/instructors')) return 'instructors';
  if (pathname.startsWith('/setup/team')) return 'first-sign-in';
  if (pathname.startsWith('/setup/domains')) return 'new-domain';
  if (pathname.startsWith('/settings/automation')) return 'changing-settings';
  if (pathname.startsWith('/settings/messages')) return 'changing-settings';
  if (pathname.startsWith('/settings/testing')) return 'testing-and-going-live';
  if (pathname.startsWith('/settings/connections')) return 'common-questions';
  if (pathname.startsWith('/activity')) return 'activity-history';
  return 'getting-started';
}
