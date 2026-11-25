// Review finding R3 (decision 347): while the beta rule is on, only an admin changes Test instructor, an
// instructor's emails or Discord account, or a team member's Discord account. The database refuses it; the forms
// say so instead of letting someone type a change that cannot be saved.
export const BETA_RECIPIENTS = 'Test instructors and signed in colleagues';

export const BETA_LOCK_NOTE =
  'During the beta, only an admin changes Test instructor, emails of an instructor and Discord accounts.';

export const betaLocked = (recipients: string | undefined, isAdmin: boolean) =>
  recipients === BETA_RECIPIENTS && !isAdmin;
