// Rollout step 1 (firestore.step1.rules): the old app (no counter claims)
// and the new app (claims the counters) both work, for new records and for
// edits, and both counters are already checked and private. LOCAL emulator
// only, with a config whose "rules" points at firestore.step1.rules:
//
//   firebase emulators:exec --config <step1 config> --only firestore --project demo-pennywise "node test/rules/rollout_step1_rules_test.mjs"

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
  const res = await fetch(`${BASE}/${path}`, { headers: headers(uid) });
  await res.text();
  return res.status;
}

const stamped = [
  { fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' },
  { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
];
const tx = (owner, id, extra = {}) => ({
  update: {
    name: `${DOCS}/users/${owner}/transactions/${id}`,
    fields: {
      amount: { integerValue: '500' }, type: { stringValue: 'expense' },
      category: { stringValue: 'food' }, description: { stringValue: 'Lunch' },
      date: { timestampValue: '2026-10-01T12:00:00Z' }, ...extra,
    },
  },
  updateTransforms: stamped,
  currentDocument: { exists: false },
});
const rule = (owner, id) => ({
  update: {
    name: `${DOCS}/users/${owner}/categoryRules/${id}`,
    fields: {
      merchantKey: { stringValue: id }, categoryId: { stringValue: 'food' },
      type: { stringValue: 'expense' }, count: { integerValue: '1' },
    },
  },
  updateTransforms: stamped,
  currentDocument: { exists: false },
});
const category = (owner, id) => ({
  update: {
    name: `${DOCS}/users/${owner}/categories/${id}`,
    fields: {
      name: { stringValue: 'Pets' }, type: { stringValue: 'expense' },
      icon: { stringValue: 'pets' }, active: { booleanValue: true },
    },
  },
  updateTransforms: stamped,
  currentDocument: { exists: false },
});
const counter = (owner, count, path) => ({
  update: {
    name: `${DOCS}/users/${owner}/limits/daily`,
    fields: { count: { integerValue: String(count) }, lastPath: { stringValue: path } },
  },
  updateTransforms: [{ fieldPath: 'at', setToServerValue: 'REQUEST_TIME' }],
});

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

// ---- Old app (today's installed build): no claims -----------------------------
expect('old app: new transaction without a claim', await commit('ola', [tx('ola', 'o1')]), true);
expect('old app: new learned category without a claim', await commit('ola', [rule('ola', 'OUT:NAIVAS')]), true);
expect('old app: new custom category without a claim', await commit('ola', [category('ola', 'c_petsabcd')]), true);

// ---- New app: claims in the same request ---------------------------------------
expect('new app: transaction with its claim', await commit('nia', [await claimWrite(env, 'nia', 'transactions/n1'), tx('nia', 'n1')]), true);
expect('new app: learned category with its claim', await commit('nia', [await claimWrite(env, 'nia', 'categoryRules/OUT:JAVA'), rule('nia', 'OUT:JAVA')]), true);
expect('new app: custom category with its claim', await commit('nia', [await claimWrite(env, 'nia', 'categories/c_bookswxyz'), category('nia', 'c_bookswxyz')]), true);
expect('new app: next claim the same day (+1)', await commit('nia', [await claimWrite(env, 'nia', 'transactions/n2'), tx('nia', 'n2')]), true);

// ---- The counter is already checked ---------------------------------------------
expect('counter can\'t skip ahead', await commit('nia', [counter('nia', 99, 'transactions/n3'), tx('nia', 'n3')]), false);
expect('counter can\'t reset the same day', await commit('nia', [counter('nia', 1, 'transactions/n4'), tx('nia', 'n4')]), false);
expect('counter can\'t be deleted outside account deletion', await commit('nia', [{ delete: `${DOCS}/users/nia/limits/daily` }]), false);
expect('counter can\'t take extra fields', await commit('nia', [{
  update: { name: `${DOCS}/users/nia/limits/daily`, fields: { count: { integerValue: '5' }, lastPath: { stringValue: 'x' }, admin: { booleanValue: true } } },
  updateTransforms: [{ fieldPath: 'at', setToServerValue: 'REQUEST_TIME' }],
}]), false);
expect('a document other than limits/daily', await commit('nia', [{
  update: { name: `${DOCS}/users/nia/limits/other`, fields: { count: { integerValue: '1' }, lastPath: { stringValue: 'x' } } },
  updateTransforms: [{ fieldPath: 'at', setToServerValue: 'REQUEST_TIME' }],
}]), false);

// ---- Counter isolation -------------------------------------------------------------
expect('owner reads own counter', await read('nia', 'users/nia/limits/daily'), true);
expect('another user reads the counter', await read('mallory', 'users/nia/limits/daily'), false);
expect('signed out reads the counter', await (async () => {
  const res = await fetch(`${BASE}/users/nia/limits/daily`);
  await res.text();
  return res.status;
})(), false);
expect('another user writes the counter', await commit('mallory', [await claimWrite(env, 'nia', 'transactions/m1')]), false);
expect('another user creates a transaction for nia', await commit('mallory', [tx('nia', 'm2')]), false);

// ---- Existing protections still apply ----------------------------------------------
expect('invalid transaction still refused (no claim needed to be refused)', await commit('ola', [tx('ola', 'o2', { type: { stringValue: 'gift' } })]), false);
expect('privileged field still refused', await commit('ola', [tx('ola', 'o3', { password: { stringValue: 'x' } })]), false);

// ---- Edits: the old app (no edit claim) and the new app (claims) both work -------
const old = { timestampValue: '2026-10-01T00:00:00Z' };
const S = (s) => ({ stringValue: s });
const I = (n) => ({ integerValue: String(n) });
const stampNow = (...f) => f.map((fieldPath) => ({ fieldPath, setToServerValue: 'REQUEST_TIME' }));
for (const u of ['ola', 'nia']) {
  for (const [path, fields] of Object.entries({
    [`users/${u}`]: { email: S(`${u}@example.com`), createdAt: old, updatedAt: old },
    [`users/${u}/accounts/mpesa-sim1`]: {
      name: S('M-Pesa'), kind: S('mobile_money'), provider: S('safaricom'),
      active: { booleanValue: true }, order: I(0), createdAt: old, updatedAt: old,
    },
  })) await commit('ADMIN', [{ update: { name: `${DOCS}/${path}`, fields } }]);
}
const edits = (u) => ({
  transaction: ['transactions/' + (u === 'ola' ? 'o1' : 'n1'), {
    update: { name: `${DOCS}/users/${u}/transactions/${u === 'ola' ? 'o1' : 'n1'}`, fields: { description: S('Edited') } },
    updateMask: { fieldPaths: ['description'] }, updateTransforms: stampNow('updatedAt'),
  }],
  account: ['accounts/mpesa-sim1', {
    update: { name: `${DOCS}/users/${u}/accounts/mpesa-sim1`, fields: { name: S('SIM 1') } },
    updateMask: { fieldPaths: ['name'] }, updateTransforms: stampNow('updatedAt'),
  }],
  profile: ['profile', {
    update: { name: `${DOCS}/users/${u}`, fields: { displayName: S('Name') } },
    updateMask: { fieldPaths: ['displayName'] }, updateTransforms: stampNow('updatedAt'),
  }],
  budget: ['budgets/2026-10', {
    update: { name: `${DOCS}/users/${u}/budgets/2026-10`, fields: { month: S('2026-10'), limit: I(20000) } },
    updateTransforms: stampNow('updatedAt'),
  }],
  'profile photo': ['private/avatar', {
    update: { name: `${DOCS}/users/${u}/private/avatar`, fields: { imageBase64: S('/9j/AAAA') } },
    updateTransforms: stampNow('updatedAt'),
  }],
});
// New accounts and balance history records: no claim needed yet.
expect('old app: new account without a claim', await commit('ola', [{
  update: {
    name: `${DOCS}/users/ola/accounts/equity-bank`,
    fields: { name: S('Equity'), kind: S('bank'), provider: S('equity'), active: { booleanValue: true }, order: I(5) },
  },
  updateTransforms: stampNow('createdAt', 'updatedAt'), currentDocument: { exists: false },
}]), true);
expect('old app: starting balance with its history record, no claims', await commit('ola', [{
  update: { name: `${DOCS}/users/ola/accounts/equity-bank`, fields: { openingBalance: I(100), openingDate: old } },
  updateMask: { fieldPaths: ['openingBalance', 'openingDate'] }, updateTransforms: stampNow('updatedAt'),
}, {
  update: {
    name: `${DOCS}/users/ola/balanceAnchors/equity-bank_1`,
    fields: {
      uid: S('ola'), accountId: S('equity-bank'), amount: I(100), effectiveAt: old,
      currency: S('KES'), reason: S('Edited'), undone: { booleanValue: false },
    },
  },
  updateTransforms: stampNow('createdAt'), currentDocument: { exists: false },
}]), true);
expect('new app: new account with its claim', await commit('nia', [await claimWrite(env, 'nia', 'accounts/new-bank'), {
  update: {
    name: `${DOCS}/users/nia/accounts/new-bank`,
    fields: { name: S('Equity'), kind: S('bank'), provider: S('equity'), active: { booleanValue: true }, order: I(5) },
  },
  updateTransforms: stampNow('createdAt', 'updatedAt'), currentDocument: { exists: false },
}]), true);

for (const [label, [, write]] of Object.entries(edits('ola'))) {
  expect(`old app: ${label} edit without a claim`, await commit('ola', [write]), true);
}
for (const [label, [path, write]] of Object.entries(edits('nia'))) {
  expect(`new app: ${label} edit with its claim`, await commit('nia', [await claimEdit(env, 'nia', path), write]), true);
}
const editCounter = (owner, count, path, extra = {}) => ({
  update: {
    name: `${DOCS}/users/${owner}/limits/edits`,
    fields: { count: I(count), lastPath: S(path), ...extra },
  },
  updateTransforms: [{ fieldPath: 'at', setToServerValue: 'REQUEST_TIME' }],
});
const niaTx = edits('nia').transaction[1];
expect('edit counter can\'t skip ahead', await commit('nia', [editCounter('nia', 99, 'transactions/n1'), niaTx]), false);
expect('edit counter can\'t reset the same day', await commit('nia', [editCounter('nia', 1, 'transactions/n1'), niaTx]), false);
expect('edit counter can\'t be deleted outside account deletion', await commit('nia', [{ delete: `${DOCS}/users/nia/limits/edits` }]), false);
const extraField = await claimEdit(env, 'nia', 'transactions/n1');
extraField.update.fields.admin = { booleanValue: true };
expect('edit counter can\'t take extra fields', await commit('nia', [extraField, niaTx]), false);
expect('owner reads own edit counter', await read('nia', 'users/nia/limits/edits'), true);
expect('another user reads the edit counter', await read('mallory', 'users/nia/limits/edits'), false);
expect('another user writes the edit counter', await commit('mallory', [await claimEdit(env, 'nia', 'transactions/n1')]), false);
expect('another user edits nia\'s data, even with a claim', await commit('mallory', [await claimEdit(env, 'nia', 'transactions/n1'), niaTx]), false);
expect('daily and edit counters are separate (old app\'s first edit claim is 1)', await commit('ola', [await claimEdit(env, 'ola', 'transactions/o1'), edits('ola').transaction[1]]), true);

console.log(failures === 0 ? '\nAll rollout step 1 rules tests passed.' : `\n${failures} rollout step 1 rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
