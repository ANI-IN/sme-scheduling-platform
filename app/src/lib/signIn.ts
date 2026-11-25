// Review finding R41 (decision 349): the sign in page shows only the app's own refusal reasons (anything else in
// the address could be written by whoever made the link), and loading the account is tried again before giving up.
const KNOWN = [
  'Sign in is not set up yet. Ask the admin to set the company email domain.',
  'Only company Google accounts can use SME Scheduling.',
  'Please sign in with your company Google account.',
  'SME Scheduling is in a closed beta. Ask an admin to add you to the beta list.',
  'Your access to SME Scheduling was removed. Ask your team lead if you think this is a mistake.',
];

export const SIGN_IN_FAILED =
  'Sign in did not work. Use your company Google account, or ask an admin.';

export function signInMessage(raw: string | null | undefined): string | null {
  if (!raw) return null;
  return KNOWN.find((k) => raw.trim() === k) ?? SIGN_IN_FAILED;
}

export async function withRetry<T>(fn: () => Promise<T>, waits: number[] = [1000, 3000]) {
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i >= waits.length) throw e;
      await new Promise((r) => setTimeout(r, waits[i]));
    }
  }
}
