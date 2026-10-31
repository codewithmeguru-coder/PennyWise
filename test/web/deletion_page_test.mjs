// The public account deletion page's logic (hosting/delete-account):
//   node --test test/web/deletion_page_test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canDelete, deleteEverything, COLLECTIONS } from '../../hosting/delete-account/deletion.mjs';

test('the button needs sign-in, the tick and DELETE typed exactly', () => {
  assert.equal(canDelete({ signedIn: true, understood: true, typed: 'DELETE' }), true);
  assert.equal(canDelete({ signedIn: true, understood: true, typed: ' DELETE ' }), true);
  assert.equal(canDelete({ signedIn: false, understood: true, typed: 'DELETE' }), false);
  assert.equal(canDelete({ signedIn: true, understood: false, typed: 'DELETE' }), false);
  assert.equal(canDelete({ signedIn: true, understood: true, typed: 'delete' }), false);
  assert.equal(canDelete({ signedIn: true, understood: true, typed: '' }), false);
  assert.equal(canDelete({}), false);
});

function fakeStore(failOnce) {
  const data = Object.fromEntries(COLLECTIONS.map((c) => [c, 450]));
  const s = {
    log: [], marker: false, profile: true, photo: true, signIn: true, failOnce,
    async markDeletion() { s.log.push('mark'); s.marker = true; },
    async deleteSome(c) {
      if (s.failOnce === c) { s.failOnce = null; throw new Error('offline'); }
      const n = Math.min(200, data[c]); data[c] -= n; return n;
    },
    async deleteDoc() { s.photo = false; },
    async clearMarker() { assert.ok(Object.values(data).every((n) => n === 0)); s.log.push('clear'); s.marker = false; },
    async deleteProfile() { s.profile = false; },
    async deleteSignIn() { s.signIn = false; },
    data,
  };
  return s;
}

test('deletes every collection, then the request, profile and sign-in', async () => {
  const s = fakeStore();
  await deleteEverything(s);
  assert.ok(Object.values(s.data).every((n) => n === 0));
  assert.deepEqual(s.log, ['mark', 'clear']);
  assert.equal(s.photo, false);
  assert.equal(s.profile, false);
  assert.equal(s.signIn, false);
});

test('stopped halfway: the request stays, and running again finishes', async () => {
  const s = fakeStore('accounts');
  await assert.rejects(deleteEverything(s));
  assert.equal(s.marker, true);
  assert.equal(s.signIn, true);
  assert.equal(s.data.transactions, 0);
  await deleteEverything(s);
  assert.ok(Object.values(s.data).every((n) => n === 0));
  assert.equal(s.marker, false);
  assert.equal(s.signIn, false);
});

test('the page shows the support email and has no placeholders left', async () => {
  const { readFile } = await import('node:fs/promises');
  const html = await readFile(new URL('../../hosting/delete-account/index.html', import.meta.url), 'utf8');
  assert.match(html, /<a href="mailto:doe68196@gmail\.com" id="contact">doe68196@gmail\.com<\/a>/);
  assert.doesNotMatch(html, /\[CONFIRM|__[A-Z_]+__/);
});
