// Regression tests for the security rules that Phase 3 does not change:
// profiles, budgets, and deletes/updates of transactions and learned rules
// by someone other than the owner. LOCAL Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/regression_rules_test.mjs"
//
// The "demo-" project id keeps the emulator from ever reaching a real
// project. No npm packages: plain REST calls with unsigned emulator tokens.

const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT = process.env.GCLOUD_PROJECT || 'demo-pennywise';
const DOCS = `projects/${PROJECT}/databases/(default)/documents`;
const BASE = `http://${HOST}/v1/${DOCS}`;

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const token = (uid) =>
  `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
    sub: uid, user_id: uid, aud: PROJECT,
    iss: `https://securetoken.google.com/${PROJECT}`,
    iat: 1, exp: 9999999999, auth_time: 1, email: `${uid}@example.com`,
    firebase: { sign_in_provider: 'google.com' },
  })}.`;

function value(v) {
  if (v === null) return { nullValue: null };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  throw new Error(`unsupported ${v}`);
}
const fields = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, value(v)]));
const headers = (uid) => ({
  'Content-Type': 'application/json',
  ...(uid ? { Authorization: `Bearer ${token(uid)}` } : {}),
});

/**
 * Writes one document as [uid] (null = signed out). [stamp] lists fields set
 * to the server time; [create] requires the document not to exist.
 */
async function write(uid, path, data, { create = false, stamp = ['updatedAt'] } = {}) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      writes: [{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: stamp.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' })),
        ...(create ? { currentDocument: { exists: false } } : { updateMask: { fieldPaths: Object.keys(data) } }),
      }],
    }),
  });
  await res.text();
  return res.status;
}

async function read(uid, path) {
  const res = await fetch(`${BASE}/${path}`, { headers: headers(uid) });
  await res.text();
  return res.status;
}

async function remove(uid, path) {
  const res = await fetch(`${BASE}/${path}`, { method: 'DELETE', headers: headers(uid) });
  await res.text();
  return res.status;
}

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

const both = ['createdAt', 'updatedAt'];
const P = 'users/rita';
const profile = { email: 'rita@example.com', displayName: 'Rita' };

// ---- Profiles: users/{uid} -------------------------------------------------
expect('profile: owner creates own profile', await write('rita', P, profile, { create: true, stamp: both }), true);
expect('profile: owner reads own profile', await read('rita', P), true);
expect('profile: owner updates display name', await write('rita', P, { displayName: 'Rita W.' }), true);
expect('profile: email different from sign-in', await write('sam', 'users/sam', { email: 'rita@example.com' }, { create: true, stamp: both }), false);
expect('profile: extra field (password)', await write('sam', 'users/sam', { email: 'sam@example.com', password: 'x' }, { create: true, stamp: both }), false);
expect('profile: photoUrl that is not https', await write('rita', P, { photoUrl: 'http://example.com/a.png' }), false);
expect('profile: owner changes createdAt', await write('rita', P, { createdAt: new Date('2020-01-01T00:00:00Z') }, { stamp: ['updatedAt'] }), false);
expect('profile: other user reads it', await read('mallory', P), false);
expect('profile: other user changes it', await write('mallory', P, { displayName: 'Hacked' }), false);
expect('profile: other user deletes it', await remove('mallory', P), false);
expect('profile: other user creates it for someone else', await write('mallory', 'users/victor', { email: 'mallory@example.com' }, { create: true, stamp: both }), false);
expect('profile: signed out reads it', await read(null, P), false);
expect('profile: signed out changes it', await write(null, P, { displayName: 'x' }), false);
expect('profile: signed out deletes it', await remove(null, P), false);

// ---- Budgets: users/{uid}/budgets/{YYYY-MM} --------------------------------
const B = `${P}/budgets`;
expect('budget: owner sets October budget', await write('rita', `${B}/2026-10`, { month: '2026-10', limit: 20000 }, { create: true }), true);
expect('budget: owner reads it', await read('rita', `${B}/2026-10`), true);
expect('budget: owner changes the limit', await write('rita', `${B}/2026-10`, { limit: 25000 }), true);
expect('budget: bad month id', await write('rita', `${B}/2026-13`, { month: '2026-13', limit: 100 }, { create: true }), false);
expect('budget: month field different from id', await write('rita', `${B}/2026-11`, { month: '2026-12', limit: 100 }, { create: true }), false);
expect('budget: limit of 0', await write('rita', `${B}/2026-11`, { month: '2026-11', limit: 0 }, { create: true }), false);
expect('budget: extra field', await write('rita', `${B}/2026-11`, { month: '2026-11', limit: 100, note: 'x' }, { create: true }), false);
expect('budget: other user reads it', await read('mallory', `${B}/2026-10`), false);
expect('budget: other user changes it', await write('mallory', `${B}/2026-10`, { limit: 1 }), false);
expect('budget: other user deletes it', await remove('mallory', `${B}/2026-10`), false);
expect('budget: signed out reads it', await read(null, `${B}/2026-10`), false);
expect('budget: signed out changes it', await write(null, `${B}/2026-10`, { limit: 1 }), false);
expect('budget: signed out deletes it', await remove(null, `${B}/2026-10`), false);
expect('budget: owner deletes it', await remove('rita', `${B}/2026-10`), true);

// ---- Transactions and learned rules: unauthorized updates and deletes -----
const T = `${P}/transactions/reg-t1`;
const R = `${P}/categoryRules/OUT:NAIVAS`;
await write('rita', T, { amount: 500, type: 'expense', category: 'food', description: 'Lunch', date: new Date('2026-10-09T12:00:00Z') }, { create: true, stamp: both });
await write('rita', R, { merchantKey: 'OUT:NAIVAS', categoryId: 'shopping', type: 'expense', count: 1 }, { create: true, stamp: both });
expect('transaction: other user changes it', await write('mallory', T, { amount: 1 }), false);
expect('transaction: other user deletes it', await remove('mallory', T), false);
expect('transaction: signed out changes it', await write(null, T, { amount: 1 }), false);
expect('transaction: signed out deletes it', await remove(null, T), false);
expect('learned rule: signed out changes it', await write(null, R, { categoryId: 'food' }), false);
expect('learned rule: signed out deletes it', await remove(null, R), false);
expect('transaction: owner deletes own', await remove('rita', T), true);
expect('learned rule: owner deletes own', await remove('rita', R), true);

console.log(failures === 0 ? '\nAll regression rules tests passed.' : `\n${failures} regression rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
