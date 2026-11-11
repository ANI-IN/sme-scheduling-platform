export const weekStatusLabel: Record<string, string> = {
  Planned: 'Not started yet',
  NotReady: 'Setup not finished',
  Ready: 'Ready to ask',
  Asking: 'Asking',
  Confirmed: 'Confirmed',
  Completed: 'Completed',
  NeedsInstructor: 'Needs an instructor',
  Cancelled: 'Cancelled',
};

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
  CheckInNoReply: 'No answer to reminder before class',
  ThinBench: 'Few instructors available',
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
