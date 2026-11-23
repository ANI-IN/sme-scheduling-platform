export const attentionTypeLabel: Record<string, string> = {
  RankingExhausted: 'Nobody left to ask',
  ClassAtRisk: 'Class at risk',
  TypedReply: 'Written reply to read',
  HelpRequest: 'Help request',
  ReadinessFailed: 'Setup check failed',
  ChecklistOverdue: 'Task overdue',
  MessageFailed: 'Message not delivered',
  LateReply: 'Reply after the request closed',
  ScheduleLow: 'Few classes planned ahead',
  TimeChangeNotConfirmed: 'Time change not confirmed',
  TimeProposal: 'Proposed time to check',
  CheckInNoReply: 'No answer to reminder before class',
  ThinBench: 'Few instructors available',
  // Not raised any more (the contact check is optional); kept for tasks from before.
  UnverifiedInRanking: 'Contact details not checked',
  OwnerCheckIn: 'Question for the owner',
  Other: 'Other',
};

export const helpCategories: { code: string; label: string }[] = [
  { code: 'materials', label: 'Class materials or content' },
  { code: 'zoom', label: 'Zoom link or calendar invite' },
  { code: 'platform', label: 'Platform access' },
  { code: 'assignment', label: 'Assignment or test review details' },
  { code: 'students', label: 'Students and cohort' },
  { code: 'schedule', label: 'Schedule question' },
  { code: 'payment', label: 'Payment or admin' },
  { code: 'other', label: 'Something else' },
];

export const helpStatusLabel: Record<string, string> = {
  Open: 'Open',
  InProgress: 'In progress',
  WaitingOnInstructor: 'Waiting on instructor',
  Resolved: 'Resolved',
  Closed: 'Closed',
  ConvertedToCancellation: 'Converted to cancellation',
};

export const historyCategories = [
  'Messages',
  'Instructor responses',
  'Bookings',
  'Team actions',
  'Setup changes',
  'Help requests',
  'Reminders',
  'System',
  'Discord',
];

/** An instructor's status in the team's words (glossary: "In use", "Not in use", "Archived"). */
export const instructorStatusLabel = (s: string | null | undefined) =>
  s === 'Active' ? 'In use' : s === 'Inactive' ? 'Not in use' : (s ?? '');

/**
 * A module's status in the team's words (glossary: "Draft", "Live", "Archived"). The database keeps its own values:
 * Active is Live (instructors are asked) and Inactive is Draft (being set up, nobody is asked).
 */
export const moduleStatusLabel = (s: string | null | undefined) =>
  s === 'Active' ? 'Live' : s === 'Inactive' ? 'Draft' : (s ?? '');
