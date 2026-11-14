// Shared, testable rules for the public account deletion page. No Firebase
// here: index.html passes in the Firestore functions it uses.

/** Every collection under users/{uid}, removed in this order (same as the app). */
export const COLLECTIONS = [
  'transactions',
  'categoryRules',
  'budgets',
  'categoryBudgets',
  'balanceAnchors',
  'accounts',
  'categories',
];

export const CONFIRM_WORD = 'DELETE';

/**
 * Whether the Delete button may be pressed: signed in (that is the proof of
 * ownership), "I understand" ticked, and DELETE typed exactly.
 */
export function canDelete({ signedIn, understood, typed }) {
  return Boolean(signedIn) && Boolean(understood) &&
    String(typed ?? '').trim() === CONFIRM_WORD;
}

/**
 * Deletes everything the signed-in user owns, then their sign-in. Safe to
 * repeat: the request record goes first and is removed only after the data,
 * so a run that stops halfway is finished by running it again.
 *
 * [fs] provides: markDeletion(), deleteSome(collection) -> count,
 * deleteDoc(path), clearWriteCounter(), clearMarker(), deleteProfile(),
 * deleteSignIn().
 */
export async function deleteEverything(fs, onStep = () => {}) {
  onStep('Recording the request');
  await fs.markDeletion();
  for (const c of COLLECTIONS) {
    onStep(`Deleting ${c}`);
    while ((await fs.deleteSome(c)) > 0) { /* next batch */ }
  }
  onStep('Deleting profile photo');
  await fs.deleteDoc('private/avatar');
  await fs.clearWriteCounter();
  await fs.clearMarker();
  onStep('Deleting profile');
  await fs.deleteProfile();
  onStep('Deleting sign-in');
  await fs.deleteSignIn();
}
