// Security rules for the daily write limit (claimsLimit in firestore.rules):
// every new transaction, learned category or custom category must claim the
// owner's counter in the same request. LOCAL emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/limits_rules_test.mjs"

import { claimWrite } from './limit.mjs';

const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT = process.env.GCLOUD_PROJECT || 'demo-pennywise';
const DOCS = `projects/${PROJECT}/databases/(default)/documents`;
const BASE = `http://${HOST}/v1/${DOCS}`;
const env = { BASE, DOCS };

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const token = (uid) =>
  `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
    sub: uid, user_id: uid, aud: PROJECT,
    iss: `https://securetoken.google.com/${PROJECT}`,
    iat: 1, exp: 9999999999, auth_time: 1, email: `${uid}@example.com`,
    firebase: { sign_in_provider: 'google.com' },
  })}.`;
const headers = (uid) => ({
  'Content-Type': 'application/json',
  Authorization: `Bearer ${uid === 'ADMIN' ? 'owner' : token(uid)}`,
});

async function commit(uid, writes) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST', headers: headers(uid), body: JSON.stringify({ writes }),
  });
  await res.text();
  return res.status;
}

const tx = (owner, id) => ({
  update: {
    name: `${DOCS}/users/${owner}/transactions/${id}`,
    fields: {
      amount: { integerValue: '500' }, type: { stringValue: 'expense' },
      category: { stringValue: 'food' }, description: { stringValue: 'Lunch' },
      date: { timestampValue: '2026-10-01T12:00:00Z' },
    },
  },
  updateTransforms: [
    { fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' },
    { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
  ],
  currentDocument: { exists: false },
});

/** A counter write with the given count and path (stamped now). */
const counter = (owner, count, path) => ({
  update: {
    name: `${DOCS}/users/${owner}/limits/daily`,
    fields: { count: { integerValue: String(count) }, lastPath: { stringValue: path } },
  },
  updateTransforms: [{ fieldPath: 'at', setToServerValue: 'REQUEST_TIME' }],
});

/** Sets the counter directly (admin), e.g. near the limit or yesterday. */
async function seedCounter(owner, count, at) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST', headers: headers('ADMIN'),
    body: JSON.stringify({ writes: [{ update: {
      name: `${DOCS}/users/${owner}/limits/daily`,
      fields: {
        count: { integerValue: String(count) },
        lastPath: { stringValue: 'transactions/seed' },
        at: { timestampValue: at.toISOString() },
      },
    } }] }),
  });
  await res.text();
}

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

// ---- Normal use -------------------------------------------------------------
expect('a new transaction with its claim', await commit('ann', [await claimWrite(env, 'ann', 'transactions/a1'), tx('ann', 'a1')]), true);
expect('the next one, counter +1', await commit('ann', [await claimWrite(env, 'ann', 'transactions/a2'), tx('ann', 'a2')]), true);

// ---- Abuse ------------------------------------------------------------------
expect('a new transaction without a claim', await commit('ann', [tx('ann', 'a3')]), false);
expect('two transactions on one claim (batch)', await commit('ann', [await claimWrite(env, 'ann', 'transactions/a4'), tx('ann', 'a4'), tx('ann', 'a5')]), false);
expect('a claim naming another document', await commit('ann', [await claimWrite(env, 'ann', 'transactions/other'), tx('ann', 'a6')]), false);
expect('a claim that skips ahead (+5)', await commit('ann', [counter('ann', 10, 'transactions/a7'), tx('ann', 'a7')]), false);
expect('a claim that resets to 1 the same day', await commit('ann', [counter('ann', 1, 'transactions/a8'), tx('ann', 'a8')]), false);
expect('the counter set to a wrong value', await commit('ann', [counter('ann', 2, 'transactions/x')]), false);
expect('the counter deleted outside account deletion', await commit('ann', [{ delete: `${DOCS}/users/ann/limits/daily` }]), false);
expect('extra fields on the counter', await commit('ann', [{ ...counter('ann', 3, 'transactions/a9'), update: { ...counter('ann', 3, 'transactions/a9').update, fields: { ...counter('ann', 3, 'transactions/a9').update.fields, bonus: { integerValue: '1' } } } }, tx('ann', 'a9')]), false);

// Re-creating a deleted transaction still costs a claim.
await commit('ann', [{ delete: `${DOCS}/users/ann/transactions/a1` }]);
expect('re-creating a deleted one without a claim', await commit('ann', [tx('ann', 'a1')]), false);
expect('re-creating it with a claim', await commit('ann', [await claimWrite(env, 'ann', 'transactions/a1'), tx('ann', 'a1')]), true);

// ---- Other users --------------------------------------------------------------
expect('another user claims and writes for ann', await commit('mallory', [await claimWrite(env, 'ann', 'transactions/m1'), tx('ann', 'm1')]), false);
expect('another user reads ann\'s counter', await (async () => {
  const res = await fetch(`${BASE}/users/ann/limits/daily`, { headers: headers('mallory') });
  await res.text();
  return res.status;
})(), false);
expect('mallory\'s own claim can\'t create in ann\'s data', await commit('mallory', [await claimWrite(env, 'mallory', 'transactions/m2'), tx('ann', 'm2')]), false);

// ---- The daily limit ----------------------------------------------------------
await seedCounter('bob', 1499, new Date());
expect('the 1,500th today', await commit('bob', [await claimWrite(env, 'bob', 'transactions/b1'), tx('bob', 'b1')]), true);
expect('the 1,501st today', await commit('bob', [await claimWrite(env, 'bob', 'transactions/b2'), tx('bob', 'b2')]), false);
await seedCounter('bob', 1500, new Date(Date.now() - 86400000));
expect('a new day starts again at 1', await commit('bob', [await claimWrite(env, 'bob', 'transactions/b3'), tx('bob', 'b3')]), true);

// ---- Learned and custom categories -----------------------------------------
const rule = (owner, id) => ({
  update: {
    name: `${DOCS}/users/${owner}/categoryRules/${id}`,
    fields: {
      merchantKey: { stringValue: id }, categoryId: { stringValue: 'food' },
      type: { stringValue: 'expense' }, count: { integerValue: '1' },
    },
  },
  updateTransforms: [
    { fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' },
    { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
  ],
  currentDocument: { exists: false },
});
expect('a learned category without a claim', await commit('cy', [rule('cy', 'OUT:NAIVAS')]), false);
expect('a learned category with its claim', await commit('cy', [await claimWrite(env, 'cy', 'categoryRules/OUT:NAIVAS'), rule('cy', 'OUT:NAIVAS')]), true);

// ---- Account deletion ----------------------------------------------------------
await commit('ann', [{
  update: { name: `${DOCS}/users/ann/deletionRequest/current`, fields: {} },
  updateTransforms: [{ fieldPath: 'requestedAt', setToServerValue: 'REQUEST_TIME' }],
}]);
expect('deleting: today\'s counter can\'t be removed (no reset)', await commit('ann', [{ delete: `${DOCS}/users/ann/limits/daily` }]), false);
expect('deleting: today\'s counter can be cleared of its path', await commit('ann', [{
  update: { name: `${DOCS}/users/ann/limits/daily`, fields: { lastPath: { stringValue: '' } } },
  updateMask: { fieldPaths: ['lastPath'] },
}]), true);
expect('deleting: the count can\'t be changed', await commit('ann', [{
  update: { name: `${DOCS}/users/ann/limits/daily`, fields: { count: { integerValue: '0' }, lastPath: { stringValue: '' } } },
  updateMask: { fieldPaths: ['count', 'lastPath'] },
}]), false);
await seedCounter('ann', 7, new Date(Date.now() - 86400000));
expect('deleting: an older counter can be removed', await commit('ann', [{ delete: `${DOCS}/users/ann/limits/daily` }]), true);

console.log(failures === 0 ? '\nAll daily limit rules tests passed.' : `\n${failures} daily limit rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
