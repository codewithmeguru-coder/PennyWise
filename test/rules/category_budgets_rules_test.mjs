// Security rules for per-category monthly limits:
// users/{uid}/categoryBudgets/{YYYY-MM}_{categoryId}. LOCAL Firestore
// emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/category_budgets_rules_test.mjs"
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

/** The app's query: one user's limits for one month. */
async function listMonth(uid, owner, month) {
  const res = await fetch(`${BASE}/users/${owner}:runQuery`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: 'categoryBudgets' }],
        where: { fieldFilter: { field: { fieldPath: 'month' }, op: 'EQUAL', value: { stringValue: month } } },
      },
    }),
  });
  const body = await res.text();
  return { status: res.status, count: res.status === 200 ? JSON.parse(body).filter((r) => r.document).length : 0 };
}

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}
function check(label, passed) {
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  check  ${label}`);
}

const C = 'users/cara/categoryBudgets';
const food = { month: '2026-10', categoryId: 'food', limit: 5000 };

// ---- Owner -------------------------------------------------------------------
expect('owner sets a food limit for October', await write('cara', `${C}/2026-10_food`, food, { create: true }), true);
expect('owner sets a fees limit (decimal)', await write('cara', `${C}/2026-10_fees`, { month: '2026-10', categoryId: 'fees', limit: 150.5 }, { create: true }), true);
expect('owner sets a September limit', await write('cara', `${C}/2026-09_food`, { ...food, month: '2026-09' }, { create: true }), true);
expect('owner reads it', await read('cara', `${C}/2026-10_food`), true);
expect('owner changes the limit', await write('cara', `${C}/2026-10_food`, { limit: 6000 }), true);
const owner = await listMonth('cara', 'cara', '2026-10');
expect('owner lists October\'s limits', owner.status, true);
check(`October lists only October (2 found: ${owner.count})`, owner.count === 2);

// ---- Shape -------------------------------------------------------------------
expect('id not matching month and category', await write('cara', `${C}/2026-10_transport`, food, { create: true }), false);
expect('id for another month', await write('cara', `${C}/2026-11_food`, food, { create: true }), false);
expect('bad month (13)', await write('cara', `${C}/2026-13_food`, { ...food, month: '2026-13' }, { create: true }), false);
expect('month without leading zero', await write('cara', `${C}/2026-1_food`, { ...food, month: '2026-1' }, { create: true }), false);
expect('category with upper case', await write('cara', `${C}/2026-10_Food`, { ...food, categoryId: 'Food' }, { create: true }), false);
expect('category with a space', await write('cara', `${C}/2026-10_my food`, { ...food, categoryId: 'my food' }, { create: true }), false);
expect('category with a slash-like dash', await write('cara', `${C}/2026-10_a-b`, { ...food, categoryId: 'a-b' }, { create: true }), false);
expect('category longer than 40', await write('cara', `${C}/2026-10_${'a'.repeat(41)}`, { ...food, categoryId: 'a'.repeat(41) }, { create: true }), false);
expect('empty category', await write('cara', `${C}/2026-10_`, { ...food, categoryId: '' }, { create: true }), false);
expect('limit of 0', await write('cara', `${C}/2026-10_health`, { month: '2026-10', categoryId: 'health', limit: 0 }, { create: true }), false);
expect('negative limit', await write('cara', `${C}/2026-10_health`, { month: '2026-10', categoryId: 'health', limit: -5 }, { create: true }), false);
expect('limit of 1,000,000,000', await write('cara', `${C}/2026-10_health`, { month: '2026-10', categoryId: 'health', limit: 1000000000 }, { create: true }), false);
expect('limit as text', await write('cara', `${C}/2026-10_health`, { month: '2026-10', categoryId: 'health', limit: '500' }, { create: true }), false);
expect('extra field', await write('cara', `${C}/2026-10_health`, { month: '2026-10', categoryId: 'health', limit: 500, note: 'x' }, { create: true }), false);
expect('missing category', await write('cara', `${C}/2026-10_health`, { month: '2026-10', limit: 500 }, { create: true }), false);
expect('updatedAt set by the phone, not the server', await write('cara', `${C}/2026-10_health`, { month: '2026-10', categoryId: 'health', limit: 500, updatedAt: new Date('2026-10-26T10:00:00Z') }, { create: true, stamp: [] }), false);
expect('update that changes the category', await write('cara', `${C}/2026-10_food`, { categoryId: 'transport' }), false);

// ---- Other users and signed out -----------------------------------------------
expect('other user reads it', await read('mallory', `${C}/2026-10_food`), false);
expect('other user lists them', (await listMonth('mallory', 'cara', '2026-10')).status, false);
expect('other user changes it', await write('mallory', `${C}/2026-10_food`, { limit: 1 }), false);
expect('other user creates one for cara', await write('mallory', `${C}/2026-10_shopping`, { month: '2026-10', categoryId: 'shopping', limit: 1 }, { create: true }), false);
expect('other user deletes it', await remove('mallory', `${C}/2026-10_food`), false);
expect('signed out reads it', await read(null, `${C}/2026-10_food`), false);
expect('signed out lists them', (await listMonth(null, 'cara', '2026-10')).status, false);
expect('signed out changes it', await write(null, `${C}/2026-10_food`, { limit: 1 }), false);
expect('signed out deletes it', await remove(null, `${C}/2026-10_food`), false);

// ---- The overall budget is unaffected ------------------------------------------
expect('overall budget still accepted as before', await write('cara', 'users/cara/budgets/2026-10', { month: '2026-10', limit: 20000 }, { create: true }), true);
expect('overall budget still refuses a category field', await write('cara', 'users/cara/budgets/2026-11', { month: '2026-11', limit: 100, categoryId: 'food' }, { create: true }), false);

// ---- Delete ----------------------------------------------------------------------
expect('owner deletes one limit', await remove('cara', `${C}/2026-10_food`), true);
expect('the other limit is still there', await read('cara', `${C}/2026-10_fees`), true);

console.log(failures === 0 ? '\nAll category budget rules tests passed.' : `\n${failures} category budget rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
