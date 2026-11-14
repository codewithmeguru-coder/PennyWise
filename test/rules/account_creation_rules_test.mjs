// Account and balance history creation: each new account and each new
// history record claims one write from the daily counter (claimsLimit), so
// neither can be created without end. LOCAL emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/account_creation_rules_test.mjs"

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

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

const S = (s) => ({ stringValue: s });
const I = (n) => ({ integerValue: String(n) });
const stamp = (...f) => f.map((fieldPath) => ({ fieldPath, setToServerValue: 'REQUEST_TIME' }));
const account = (u, id) => ({
  update: {
    name: `${DOCS}/users/${u}/accounts/${id}`,
    fields: {
      name: S('Bank'), kind: S('bank'), provider: S('other_bank'),
      active: { booleanValue: true }, order: I(5),
    },
  },
  updateTransforms: stamp('createdAt', 'updatedAt'),
  currentDocument: { exists: false },
});
// A history record matching the account's current (unchanged) values:
// valid by itself, which is why it must claim.
const anchor = (u, id, accountId = 'acct-1') => ({
  update: {
    name: `${DOCS}/users/${u}/balanceAnchors/${id}`,
    fields: {
      uid: S(u), accountId: S(accountId), currency: S('KES'),
      reason: S('Edited'), undone: { booleanValue: false },
    },
  },
  updateTransforms: stamp('createdAt'),
  currentDocument: { exists: false },
});

// ---- Accounts --------------------------------------------------------------
expect('new account without a claim', await commit('acc', [account('acc', 'acct-1')]), false);
expect('new account with its claim', await commit('acc', [await claimWrite(env, 'acc', 'accounts/acct-1'), account('acc', 'acct-1')]), true);
expect('two new accounts on one claim', await commit('acc', [await claimWrite(env, 'acc', 'accounts/acct-2'), account('acc', 'acct-2'), account('acc', 'acct-3')]), false);
expect('a claim naming another account', await commit('acc', [await claimWrite(env, 'acc', 'accounts/acct-9'), account('acc', 'acct-4')]), false);
expect('another user creates an account for acc', await commit('mallory', [await claimWrite(env, 'acc', 'accounts/acct-5'), account('acc', 'acct-5')]), false);

// ---- Balance history records ------------------------------------------------
expect('history record for an unchanged account, without a claim', await commit('acc', [anchor('acc', 'h1')]), false);
expect('history record with its claim', await commit('acc', [await claimWrite(env, 'acc', 'balanceAnchors/h1'), anchor('acc', 'h1')]), true);
expect('two history records on one claim', await commit('acc', [await claimWrite(env, 'acc', 'balanceAnchors/h2'), anchor('acc', 'h2'), anchor('acc', 'h3')]), false);
// A new account and its first history record in one request would need
// two new-record claims; the app never does this (history is only written
// for an existing account), so it is refused.
expect('new account + history record in one request', await commit('acc', [
  await claimWrite(env, 'acc', 'accounts/acct-6'), account('acc', 'acct-6'), anchor('acc', 'h4', 'acct-6'),
]), false);

// ---- The daily limit covers them -----------------------------------------------
await commit('ADMIN', [{
  update: { name: `${DOCS}/users/lim/limits/daily`, fields: { count: I(1499), lastPath: S('x') } },
  updateTransforms: stamp('at'),
}]);
expect('the 1,500th new record today (an account)', await commit('lim', [await claimWrite(env, 'lim', 'accounts/acct-1'), account('lim', 'acct-1')]), true);
expect('the 1,501st (another account)', await commit('lim', [await claimWrite(env, 'lim', 'accounts/acct-2'), account('lim', 'acct-2')]), false);
expect('the 1,501st (a history record)', await commit('lim', [await claimWrite(env, 'lim', 'balanceAnchors/h1'), anchor('lim', 'h1')]), false);

console.log(failures === 0 ? '\nAll account creation rules tests passed.' : `\n${failures} account creation rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
