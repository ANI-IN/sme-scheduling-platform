// Review finding R11 (decision 349): "Send last message again" offers only the newest message to the person who is
// booked or being asked now, never a closing or cancellation notice, and only one that left or could not leave.
export type ResendMessage = {
  id: string;
  audience: string;
  direction: string;
  template_id: string;
  status: string;
  blocked: boolean | null;
  instructor_id: string | null;
};

const NOTICES = new Set(['M3', 'M11', 'M12', 'M16']);

export function resendCandidate<T extends ResendMessage>(
  newestFirst: T[],
  currentInstructor: string | null,
): T | null {
  if (!currentInstructor) return null;
  return (
    newestFirst.find(
      (m) =>
        m.audience === 'Instructor' &&
        m.direction === 'Outbound' &&
        m.instructor_id === currentInstructor &&
        !NOTICES.has(m.template_id) &&
        (m.status === 'Sent' || m.status === 'Failed' || (m.status === 'Cancelled' && !!m.blocked)),
    ) ?? null
  );
}
