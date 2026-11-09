export const weekStatusLabel: Record<string, string> = {
  Planned: 'Not ready',
  NotReady: 'Not ready',
  Ready: 'Ready',
  Asking: 'Asking',
  Confirmed: 'Confirmed',
  Completed: 'Completed',
  NeedsInstructor: 'Needs instructor',
  Cancelled: 'Cancelled',
};

export const attentionTypeLabel: Record<string, string> = {
  RankingExhausted: 'Ranking exhausted',
  ClassAtRisk: 'Class at risk',
  TypedReply: 'Typed reply to read',
  HelpRequest: 'Need Help request',
  ReadinessFailed: 'Readiness check failed',
  ChecklistOverdue: 'Checklist item overdue',
  MessageFailed: 'Message failed / bounced',
  LateReply: 'Late reply after request closed',
  ScheduleLow: 'Schedule running low',
  TimeChangeNotConfirmed: 'Time change not confirmed',
  CheckInNoReply: 'Check-in not answered',
  ThinBench: 'Thin bench',
  UnverifiedInRanking: 'Instructor not verified',
  OwnerCheckIn: 'Owner check-in',
  Other: 'Other',
};

export const helpCategories: { code: string; label: string }[] = [
  { code: 'materials', label: 'Class materials or content' },
  { code: 'zoom', label: 'Zoom / meeting link or calendar invite' },
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
];
