/**
 * The "The shared class keeps the times of" choice in the Share dialog. The database needs the choice made (the
 * host's ID for this class week) when the class weeks have different times; until then the dialog shows
 * "Choose whose times". When the times are the same, nothing needs choosing and it shows this class week.
 */
export function timesChoice(
  timesFrom: string,
  hostId: string,
  differentTimes: boolean | undefined,
): { value: string; needsChoice: boolean } {
  if (timesFrom) return { value: timesFrom, needsChoice: false };
  return differentTimes ? { value: '', needsChoice: true } : { value: hostId, needsChoice: false };
}

/** A class week taken out of the share: if the shared class kept its times, the choice is made again. */
export function withoutGuest(
  chosen: string[],
  id: string,
  timesFrom: string,
): { chosen: string[]; timesFrom: string } {
  return { chosen: chosen.filter((x) => x !== id), timesFrom: timesFrom === id ? '' : timesFrom };
}
