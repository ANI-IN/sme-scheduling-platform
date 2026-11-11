// Plain-language layer for text that is written by the database (task titles, History actions,
// error messages). The database keeps its wording; the app shows it in the team's words.
// See docs/GLOSSARY.md.
import { discordNames } from './discordNames';

/** Names of the messages the system sends (template ids in the database). */
export const messageName: Record<string, string> = {
  M1: 'request to teach',
  M2: 'reminder about the request',
  M3: 'note that the request has closed',
  M4: 'confirmation',
  M5: 'class time change',
  M6: 'reminder before class',
  M7: 'final reminder before class',
  M8: 'early reminder before class',
  M9: 'follow up reminder',
  M10: 'cancellation note',
  M11: 'class cancelled note',
  M12: 'request withdrawn note',
  M13: 'help request receipt',
  M14: 'reply',
  M15: 'contact check',
  M16: 'release note',
  T0: 'test alert',
  T1: 'alert that requests have started',
  T2: 'confirmation alert',
  T3: 'decline alert',
  T4: 'alert that no instructors are left',
  T5: 'class at risk alert',
  T7: 'help request alert',
  T8: 'setup check alert',
  T9: 'task alert',
  T11: 'owner summary',
  T12: 'daily summary',
  T13: 'alert to the leads',
  T14: 'problem alert',
  T15: 'daily system summary',
  R1: 'urgent alert',
  REM: 'reminder',
  IN: 'reply',
};

const REPLACEMENTS: [RegExp, string][] = [
  // Whole database values first, before the word by word rules below can change part of them.
  [/^Not verified$/, 'Contact details not checked'],
  [/^Help pending$/, 'Help request open'],
  [/^Skipped$/, 'Skipped by the team'],
  [/^Booking released$/, 'Released'],
  [/^Clash$/, 'Clash with another class'],
  [/\bOutreach has restarted automatically\./g, "We've started asking the next instructor."],
  [
    /\bOutreach is paused for this week [—–] resume it in the class drawer when ready\./g,
    'Asking is paused for this class week. Resume it from the class week when you are ready.',
  ],
  [/\badd instructors to the ranking\b/g, 'add instructors to the instructor order'],
  [/^Ranking exhausted [—–] needs instructor$/g, 'Nobody left to ask'],
  [/\bOutreach started\b/g, 'Asking started'],
  [/\s+[—–]\s+/g, ': '],
  [/[—–]/g, ' to '],
  [/\be\.g\./gi, 'for example'],
  [/\bNeeds instructor: /g, 'No instructor yet for '],
  [/\bAt risk: /g, 'At risk: '],
  [/\bReadiness check failed\b/g, 'Setup check needs fixing'],
  [/\bReadiness check passed\b/g, 'Setup check passed'],
  [/\breadiness check\b/gi, 'setup check'],
  [/\bNot verified: /g, 'Contact details not checked: '],
  [/\bThin bench: /g, 'Not enough instructors: '],
  [/\bactive instructors? \(minimum (\d+)\)/g, 'available (at least $1 needed)'],
  [/\bUnder (\d+) days and no instructor yet: /g, 'Less than $1 days left and no instructor yet: '],
  [/\bChecklist overdue: /g, 'Class tasks overdue: '],
  [/\bChecklist pending: /g, 'Class tasks not finished: '],
  [/\bNeed help: /g, 'Help requested: '],
  [/\bZoom \/ meeting link or calendar invite\b/g, 'Zoom link or calendar invite'],
  [/\bTyped reply from /g, 'Written reply from '],
  [/\bLate "Yes" from /g, 'Late yes from '],
  [/\bNew time not confirmed: /g, 'New class time not confirmed: '],
  [/\bNo reply to the (\d+)-day check-in: /g, 'No answer to the reminder $1 days before class: '],
  [/\b(\d+)-day check-in\b/g, 'reminder $1 days before class'],
  [/\bcheck-ins?\b/gi, 'reminder before class'],
  [/\bSchedule running low: /g, 'Few classes planned: '],
  [/\bEscalation: /g, 'Sent to the leads: '],
  [
    /\bmodule weeks?\b/gi,
    (m: string) => (m.toLowerCase().endsWith('s') ? 'class weeks' : 'class week'),
  ] as never,
  [/\branking\b/gi, 'instructor order'],
  [/\bchecklist( items?)?\b/gi, (m: string) => (m[0] === 'C' ? 'Tasks' : 'tasks')] as never,
  [/\bHourly check\b/g, 'Automatic check'],
  [/\bhourly check\b/g, 'automatic check'],
  [/\bkill switch\b/gi, 'pause on all messages'],
  [/\btest clock\b/gi, 'practice clock'],
  [/\bOps contacts\b/g, 'Operations team'],
  [/\bops contacts\b/g, 'operations team'],
  [/\bverified\b/g, 'contact details checked'],
  [/\bOutreach changed by ops\b/g, 'The team changed who is asked'],
  [/\bReleased by ops\b/g, 'Released by the team'],
  [/\bby ops\b/g, 'by the team'],
  [/\bwas deactivated\b/g, 'is no longer in use'],
  [/\bInactive\b/g, 'Not in use'],
  [/\bOutreach\b/g, 'Instructor requests'],
  [/\boutreach\b/g, 'instructor requests'],
  [/ · /g, ', '],
];

/** Rewrite database text into the team's plain words (no dashes, glossary terms). */
export function plain(text: string | null | undefined): string {
  if (!text) return '';
  let s = discordNames(text);
  for (const [re, to] of REPLACEMENTS) s = s.replace(re, to as string);
  return s.replace(/\s{2,}/g, ' ').trim();
}

/** "Sun Jan 31 + Thu Feb 4" style labels read better with "and". */
export function plainLabel(text: string | null | undefined): string {
  return plain(text).replace(/ \+ /g, ' and ');
}

/** A message's name for a label or badge: "Reminder before class". */
export function messageTitle(id: string | null | undefined): string {
  const n = (id && messageName[id]) || 'message';
  return n.charAt(0).toUpperCase() + n.slice(1);
}
