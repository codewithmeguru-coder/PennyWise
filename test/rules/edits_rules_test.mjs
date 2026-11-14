// Security rules for the daily edit limit (claimsEdit, users/{uid}/limits/edits):
// every protected update claims exactly one edit in the same request, the
// counter can't be skipped, reset, deleted or reused, and account-deletion
// cleanup claims nothing. LOCAL emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/edits_rules_test.mjs"

import { claimEdit, claimWrite } from './limit.mjs';

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
async function read(uid, path) {
  const res = await fetch(`${BASE}/${path}`, { headers: uid ? headers(uid) : {} });
  await res.text();
  return res.status;
}

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

// ---- Data ------------------------------------------------------------------
const T = (iso) => ({ timestampValue: iso });
const S = (s) => ({ stringValue: s });
const I = (n) => ({ integerValue: String(n) });
const old = T('2026-10-01T00:00:00Z');
const seeds = (u) => ({
  [`users/${u}`]: { email: S(`${u}@example.com`), createdAt: old, updatedAt: old },
  [`users/${u}/transactions/t1`]: {
    amount: I(500), type: S('expense'), category: S('food'),
    description: S('Lunch'), date: old, createdAt: old, updatedAt: old,
  },
  [`users/${u}/transactions/t2`]: {
    amount: I(700), type: S('expense'), category: S('food'),
    description: S('Dinner'), date: old, createdAt: old, updatedAt: old,
  },
  [`users/${u}/categoryRules/OUT:NAIVAS`]: {
    merchantKey: S('OUT:NAIVAS'), categoryId: S('shopping'), type: S('expense'),
    count: I(1), createdAt: old, updatedAt: old,
  },
  [`users/${u}/accounts/mpesa-sim1`]: {
    name: S('M-Pesa'), kind: S('mobile_money'), provider: S('safaricom'),
    active: { booleanValue: true }, order: I(0), createdAt: old, updatedAt: old,
  },
  [`users/${u}/categories/c_petsabcd`]: {
    name: S('Pets'), type: S('expense'), icon: S('pets'),
    active: { booleanValue: true }, createdAt: old, updatedAt: old,
  },
});
async function seed(u) {
  for (const [path, fields] of Object.entries(seeds(u))) {
    await commit('ADMIN', [{ update: { name: `${DOCS}/${path}`, fields } }]);
  }
}
const stamp = (...f) => f.map((fieldPath) => ({ fieldPath, setToServerValue: 'REQUEST_TIME' }));

// One edit of each protected kind (fields changed with a mask, so the rest,
// including createdAt, stays).
const edits = (u) => ({
  'profile (update)': ['profile', {
    update: { name: `${DOCS}/users/${u}`, fields: { displayName: S('Ari') } },
    updateMask: { fieldPaths: ['displayName'] }, updateTransforms: stamp('updatedAt'),
  }],
  'transaction': ['transactions/t1', {
    update: { name: `${DOCS}/users/${u}/transactions/t1`, fields: { description: S('Lunch out') } },
    updateMask: { fieldPaths: ['description'] }, updateTransforms: stamp('updatedAt'),
  }],
  'learned category': ['categoryRules/OUT:NAIVAS', {
    update: { name: `${DOCS}/users/${u}/categoryRules/OUT:NAIVAS`, fields: { count: I(2) } },
    updateMask: { fieldPaths: ['count'] }, updateTransforms: stamp('updatedAt'),
  }],
  'account': ['accounts/mpesa-sim1', {
    update: { name: `${DOCS}/users/${u}/accounts/mpesa-sim1`, fields: { name: S('M-Pesa SIM 1') } },
    updateMask: { fieldPaths: ['name'] }, updateTransforms: stamp('updatedAt'),
  }],
  'custom category': ['categories/c_petsabcd', {
    update: { name: `${DOCS}/users/${u}/categories/c_petsabcd`, fields: { name: S('Pet care') } },
    updateMask: { fieldPaths: ['name'] }, updateTransforms: stamp('updatedAt'),
  }],
  'budget': ['budgets/2026-10', {
    update: { name: `${DOCS}/users/${u}/budgets/2026-10`, fields: { month: S('2026-10'), limit: I(20000) } },
    updateTransforms: stamp('updatedAt'),
  }],
  'category limit': ['categoryBudgets/2026-10_food', {
    update: {
      name: `${DOCS}/users/${u}/categoryBudgets/2026-10_food`,
      fields: { month: S('2026-10'), categoryId: S('food'), limit: I(5000) },
    },
    updateTransforms: stamp('updatedAt'),
  }],
  'profile photo': ['private/avatar', {
    update: { name: `${DOCS}/users/${u}/private/avatar`, fields: { imageBase64: S('/9j/AAAA') } },
    updateTransforms: stamp('updatedAt'),
  }],
});

// ---- Every protected update needs its claim ---------------------------------
await seed('ari');
for (const [label, [path, write]] of Object.entries(edits('ari'))) {
  expect(`${label}: without an edit claim`, await commit('ari', [write]), false);
  expect(`${label}: with its edit claim`, await commit('ari', [await claimEdit(env, 'ari', path), write]), true);
  // Saving the same document again is another edit, with another claim.
  expect(`${label}: again, with the next claim`, await commit('ari', [await claimEdit(env, 'ari', path), write]), true);
}

// The profile is created with a claim too (else delete + re-create would
// be an unlimited edit).
const newProfile = (u) => ({
  update: { name: `${DOCS}/users/${u}`, fields: { email: S(`${u}@example.com`) } },
  updateTransforms: stamp('createdAt', 'updatedAt'),
  currentDocument: { exists: false },
});
expect('profile (create): without a claim', await commit('pat', [newProfile('pat')]), false);
expect('profile (create): with its claim', await commit('pat', [await claimEdit(env, 'pat', 'profile'), newProfile('pat')]), true);
// Exactly as the app saves it at sign-up: name set, no Google photo.
const appProfile = (u) => ({
  update: {
    name: `${DOCS}/users/${u}`,
    fields: { email: S(`${u}@example.com`), displayName: S('New User'), photoUrl: { nullValue: null } },
  },
  updateTransforms: stamp('createdAt', 'updatedAt'),
  currentDocument: { exists: false },
});
expect('profile as the app saves it at sign-up, with its claim', await commit('sal', [await claimEdit(env, 'sal', 'profile'), appProfile('sal')]), true);

// ---- Claims can't be skipped, reused or stretched ---------------------------
const e = edits('ari');
const txEdit = e.transaction[1];
const t2Edit = {
  update: { name: `${DOCS}/users/ari/transactions/t2`, fields: { description: S('Supper') } },
  updateMask: { fieldPaths: ['description'] }, updateTransforms: stamp('updatedAt'),
};
expect('a claim naming another document', await commit('ari', [await claimEdit(env, 'ari', 'transactions/t2'), txEdit]), false);
expect('two edits on one claim (batch)', await commit('ari', [await claimEdit(env, 'ari', 'transactions/t1'), txEdit, t2Edit]), false);
const reused = await claimEdit(env, 'ari', 'transactions/t1');
expect('a claim used once', await commit('ari', [reused, txEdit]), true);
expect('the same claim used again (count not +1)', await commit('ari', [reused, txEdit]), false);
const counterWrite = (u, count, path, extra = {}) => ({
  update: {
    name: `${DOCS}/users/${u}/limits/edits`,
    fields: { count: I(count), lastPath: S(path), ...extra },
  },
  updateTransforms: stamp('at'),
});
expect('edit counter can\'t skip ahead', await commit('ari', [counterWrite('ari', 999, 'transactions/t1'), txEdit]), false);
expect('edit counter can\'t reset the same day', await commit('ari', [counterWrite('ari', 1, 'transactions/t1'), txEdit]), false);
expect('edit counter can\'t be deleted', await commit('ari', [{ delete: `${DOCS}/users/ari/limits/edits` }]), false);
const extra = await claimEdit(env, 'ari', 'transactions/t1');
extra.update.fields.admin = { booleanValue: true };
expect('edit counter can\'t take extra fields', await commit('ari', [extra, txEdit]), false);
const backdated = await claimEdit(env, 'ari', 'transactions/t1');
backdated.update.fields.at = old;
delete backdated.updateTransforms;
expect('edit counter can\'t be backdated', await commit('ari', [backdated, txEdit]), false);
expect('no counter other than daily and edits', await commit('ari', [{
  update: { name: `${DOCS}/users/ari/limits/edits2`, fields: { count: I(1), lastPath: S('transactions/t1') } },
  updateTransforms: stamp('at'),
}, txEdit]), false);
expect('the daily (new records) counter can\'t pay for an edit', await commit('ari', [await claimWrite(env, 'ari', 'transactions/t1'), txEdit]), false);
expect('an edit claim can\'t pay for a new record', await commit('ari', [await claimEdit(env, 'ari', 'transactions/t9'), {
  update: {
    name: `${DOCS}/users/ari/transactions/t9`,
    fields: { amount: I(5), type: S('expense'), category: S('food'), description: S('Tea'), date: old },
  },
  updateTransforms: stamp('createdAt', 'updatedAt'), currentDocument: { exists: false },
}]), false);
expect('a new record and an edit in one request, each with its claim', await commit('ari', [
  await claimWrite(env, 'ari', 'transactions/t8'), await claimEdit(env, 'ari', 'transactions/t1'), txEdit, {
    update: {
      name: `${DOCS}/users/ari/transactions/t8`,
      fields: { amount: I(5), type: S('expense'), category: S('food'), description: S('Tea'), date: old },
    },
    updateTransforms: stamp('createdAt', 'updatedAt'), currentDocument: { exists: false },
  }]), true);

// ---- Deletes claim nothing ----------------------------------------------------
expect('deleting a transaction needs no claim', await commit('ari', [{ delete: `${DOCS}/users/ari/transactions/t2` }]), true);

// ---- Balance history: the account edit claims; the record needs none ---------
const anchorTime = '2026-10-05T00:00:00Z';
const setOpening = {
  update: { name: `${DOCS}/users/ari/accounts/mpesa-sim1`, fields: { openingBalance: I(100), openingDate: T(anchorTime) } },
  updateMask: { fieldPaths: ['openingBalance', 'openingDate'] }, updateTransforms: stamp('updatedAt'),
};
const anchor = {
  update: {
    name: `${DOCS}/users/ari/balanceAnchors/a1`,
    fields: {
      uid: S('ari'), accountId: S('mpesa-sim1'), amount: I(100), effectiveAt: T(anchorTime),
      currency: S('KES'), reason: S('Edited'), undone: { booleanValue: false },
    },
  },
  updateTransforms: stamp('createdAt'), currentDocument: { exists: false },
};
expect('starting balance + history record without a claim', await commit('ari', [setOpening, anchor]), false);
expect('starting balance + history record, edit claim only', await commit('ari', [await claimEdit(env, 'ari', 'accounts/mpesa-sim1'), setOpening, anchor]), false);
expect('starting balance + history record, edit claim + new-record claim', await commit('ari', [await claimEdit(env, 'ari', 'accounts/mpesa-sim1'), await claimWrite(env, 'ari', 'balanceAnchors/a1'), setOpening, anchor]), true);
const clearOpening = {
  update: { name: `${DOCS}/users/ari/accounts/mpesa-sim1`, fields: {} },
  updateMask: { fieldPaths: ['openingBalance', 'openingDate'] }, updateTransforms: stamp('updatedAt'),
};
const undo = {
  update: { name: `${DOCS}/users/ari/balanceAnchors/a1`, fields: { undone: { booleanValue: true } } },
  updateMask: { fieldPaths: ['undone'] }, updateTransforms: stamp('undoneAt'),
};
expect('undo without a claim', await commit('ari', [clearOpening, undo]), false);
expect('undo, one edit claim (the account)', await commit('ari', [await claimEdit(env, 'ari', 'accounts/mpesa-sim1'), clearOpening, undo]), true);

// ---- Isolation ------------------------------------------------------------------
expect('owner reads own edit counter', await read('ari', 'users/ari/limits/edits'), true);
expect('another user reads the edit counter', await read('mallory', 'users/ari/limits/edits'), false);
expect('signed out reads the edit counter', await read(null, 'users/ari/limits/edits'), false);
expect('another user claims ari\'s counter and edits ari\'s data', await commit('mallory', [await claimEdit(env, 'ari', 'transactions/t1'), txEdit]), false);
expect('mallory\'s own claim can\'t edit ari\'s data', await commit('mallory', [await claimEdit(env, 'mallory', 'transactions/t1'), txEdit]), false);
expect('another user writes ari\'s counter alone', await commit('mallory', [await claimEdit(env, 'ari', 'transactions/t1')]), false);
expect('counters are separate per user (mallory\'s first claim is 1)', await commit('mallory', [await claimEdit(env, 'mallory', 'x')]), true);

// ---- The limit: 3,000 a UTC day ---------------------------------------------------
await seed('edd');
const eddEdit = edits('edd').transaction[1];
await commit('ADMIN', [{
  update: { name: `${DOCS}/users/edd/limits/edits`, fields: { count: I(2999), lastPath: S('x') } },
  updateTransforms: stamp('at'),
}]);
expect('the 3,000th edit today', await commit('edd', [await claimEdit(env, 'edd', 'transactions/t1'), eddEdit]), true);
expect('the 3,001st edit today', await commit('edd', [await claimEdit(env, 'edd', 'transactions/t1'), eddEdit]), false);
expect('the 3,001st by writing the counter as 3001 directly', await commit('edd', [counterWrite('edd', 3001, 'transactions/t1'), eddEdit]), false);
expect('at the edit limit, new records still work (separate counter)', await commit('edd', [await claimWrite(env, 'edd', 'transactions/e1'), {
  update: {
    name: `${DOCS}/users/edd/transactions/e1`,
    fields: { amount: I(5), type: S('expense'), category: S('food'), description: S('Tea'), date: old },
  },
  updateTransforms: stamp('createdAt', 'updatedAt'), currentDocument: { exists: false },
}]), true);
// Yesterday's full counter: today starts again at 1.
await commit('ADMIN', [{
  update: {
    name: `${DOCS}/users/edd/limits/edits`,
    fields: { count: I(3000), lastPath: S('x'), at: T(new Date(Date.now() - 86400000).toISOString()) },
  },
}]);
expect('a new UTC day: the first edit is 1', await commit('edd', [await claimEdit(env, 'edd', 'transactions/t1'), eddEdit]), true);
expect('a new UTC day: can\'t carry on from yesterday\'s count', await commit('edd', [counterWrite('edd', 3002, 'transactions/t1'), eddEdit]), false);

// ---- Account deletion: the cleanup claims nothing ----------------------------------
// ari's edit counter was used today.
const scrub = (u, name) => ({
  update: { name: `${DOCS}/users/${u}/limits/${name}`, fields: { lastPath: S('') } },
  updateMask: { fieldPaths: ['lastPath'] },
});
expect('clearing the edit counter without a deletion request', await commit('ari', [scrub('ari', 'edits')]), false);
await commit('ari', [{
  update: { name: `${DOCS}/users/ari/deletionRequest/current`, fields: {} },
  updateTransforms: stamp('requestedAt'),
}]);
expect('deleting: records go without any claim', await commit('ari', [{ delete: `${DOCS}/users/ari/accounts/mpesa-sim1` }]), true);
expect('deleting: today\'s edit counter can\'t be removed (would reset it)', await commit('ari', [{ delete: `${DOCS}/users/ari/limits/edits` }]), false);
expect('deleting: today\'s edit counter can\'t be lowered', await commit('ari', [{
  update: { name: `${DOCS}/users/ari/limits/edits`, fields: { count: I(0), lastPath: S('') } },
  updateMask: { fieldPaths: ['count', 'lastPath'] },
}]), false);
expect('deleting: today\'s edit counter is cleared of its path (no claim)', await commit('ari', [scrub('ari', 'edits')]), true);
expect('deleting: another user can\'t clear it', await commit('mallory', [scrub('ari', 'edits')]), false);
// An older counter can be removed.
await commit('ADMIN', [{
  update: {
    name: `${DOCS}/users/ari/limits/edits`,
    fields: { count: I(4), lastPath: S('x'), at: T(new Date(Date.now() - 86400000).toISOString()) },
  },
}]);
expect('deleting: an edit counter from an earlier day is removed', await commit('ari', [{ delete: `${DOCS}/users/ari/limits/edits` }]), true);

console.log(failures === 0 ? '\nAll edit limit rules tests passed.' : `\n${failures} edit limit rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
