// Stage 3 security-rules tests: the user's own accounts and the account
// ids / SIM on transactions. LOCAL Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/accounts_rules_test.mjs"
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
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  throw new Error(`unsupported ${v}`);
}
const fields = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, value(v)]));
const headers = (uid) => ({
  'Content-Type': 'application/json',
  ...(uid ? { Authorization: `Bearer ${token(uid)}` } : {}),
});

async function write(uid, path, data, { create = false } = {}) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      writes: [{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: [
          ...(create ? [{ fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' }] : []),
          { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
        ],
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

const A = 'users/nia/accounts';
const T = 'users/nia/transactions';
const sim1 = { name: 'SIM 1 M-Pesa', kind: 'mobile_money', provider: 'safaricom', simSlot: 0, active: true, order: 0 };
const day = new Date('2026-10-22T09:00:00Z');
const tx = (id, data) => write('nia', `${T}/${id}`, { amount: 100, category: 'transfer', description: 'x', date: day, ...data }, { create: true });

// ---- Accounts --------------------------------------------------------------
expect('account: owner creates SIM 1 M-Pesa', await write('nia', `${A}/mpesa-sim1`, sim1, { create: true }), true);
expect('account: owner creates Fuliza (SIM 2) loan', await write('nia', `${A}/fuliza-sim2`, { name: 'Fuliza (SIM 2)', kind: 'loan', provider: 'safaricom', simSlot: 1, parentId: 'mpesa-sim2', active: true, order: 12 }, { create: true }), true);
expect('account: owner creates Equity with opening balance', await write('nia', `${A}/equity-bank`, { name: 'Equity Bank', kind: 'bank', provider: 'equity', openingBalance: 2500.5, openingDate: day, active: true, order: 100 }, { create: true }), true);
expect('account: owner reads own', await read('nia', `${A}/mpesa-sim1`), true);
expect('account: owner renames and hides', await write('nia', `${A}/mpesa-sim1`, { name: 'Line 1', active: false }), true);
expect('account: even the owner cannot delete', await remove('nia', `${A}/mpesa-sim1`), false);
expect('account: other user reads it', await read('mallory', `${A}/mpesa-sim1`), false);
expect('account: other user creates one in your account', await write('mallory', `${A}/evil`, { ...sim1, name: 'x' }, { create: true }), false);
expect('account: other user changes it', await write('mallory', `${A}/mpesa-sim1`, { name: 'x' }), false);
expect('account: signed out reads it', await read(null, `${A}/mpesa-sim1`), false);
expect('account: signed out creates one', await write(null, `${A}/x`, sim1, { create: true }), false);
expect('account: unknown kind', await write('nia', `${A}/x1`, { ...sim1, kind: 'crypto' }, { create: true }), false);
expect('account: unknown provider', await write('nia', `${A}/x2`, { ...sim1, provider: 'mybank' }, { create: true }), false);
expect('account: extra field', await write('nia', `${A}/x3`, { ...sim1, pin: '1234' }, { create: true }), false);
expect('account: bad id (upper case)', await write('nia', `${A}/SIM1`, sim1, { create: true }), false);
expect('account: SIM slot 7', await write('nia', `${A}/x4`, { ...sim1, simSlot: 7 }, { create: true }), false);
expect('account: name too long', await write('nia', `${A}/x5`, { ...sim1, name: 'x'.repeat(41) }, { create: true }), false);
expect('account: active not a boolean', await write('nia', `${A}/x6`, { ...sim1, active: 'yes' }, { create: true }), false);
expect('account: changing createdAt', await write('nia', `${A}/mpesa-sim1`, { createdAt: new Date('2020-01-01T00:00:00Z') }), false);

// ---- Transactions with account ids and SIM ---------------------------------
expect('tx: SIM 1 -> SIM 2 transfer by account ids', await tx('t1', { type: 'transfer', account: 'mpesa', accountId: 'mpesa-sim1', toAccountId: 'mpesa-sim2', simSlot: 0 }), true);
expect('tx: Fuliza draw (loan -> M-Pesa) by ids', await tx('t2', { type: 'transfer', toAccount: 'mpesa', accountId: 'fuliza-sim1', toAccountId: 'mpesa-sim1', fee: 0.5 }), true);
expect('tx: Ziidi contribution with toAccountId', await tx('t3', { type: 'savings_contribution', category: 'savings', account: 'mpesa', accountId: 'mpesa-sim2', toAccountId: 'ziidi-sim2', simSlot: 1 }), true);
expect('tx: Fuliza repayment into the loan account', await tx('t4', { type: 'debt_repayment', category: 'debt_repayment', account: 'mpesa', accountId: 'mpesa-sim1', toAccountId: 'fuliza-sim1' }), true);
expect('tx: expense on SIM 2 with SIM recorded', await tx('t5', { type: 'expense', category: 'food', account: 'mpesa', accountId: 'mpesa-sim2', simSlot: 1 }), true);
expect('tx: older generic transfer still works', await tx('t6', { type: 'transfer', account: 'mpesa', toAccount: 'cash' }), true);
expect('tx: transfer to the same account id', await tx('t7', { type: 'transfer', accountId: 'mpesa-sim1', toAccountId: 'mpesa-sim1' }), false);
expect('tx: transfer with neither pair', await tx('t8', { type: 'transfer', accountId: 'mpesa-sim1' }), false);
expect('tx: toAccountId on an expense', await tx('t9', { type: 'expense', category: 'food', accountId: 'mpesa-sim1', toAccountId: 'cash' }), false);
expect('tx: bad account id', await tx('t10', { type: 'expense', category: 'food', accountId: 'Mpesa SIM1!' }), false);
expect('tx: SIM slot 5', await tx('t11', { type: 'expense', category: 'food', simSlot: 5 }), false);
expect('tx: other user writes with your account ids', await write('mallory', `${T}/t12`, { amount: 1, type: 'expense', category: 'food', description: 'x', date: day, accountId: 'mpesa-sim1' }, { create: true }), false);

// ---- Transfers carrying both the generic pair and the account ids ----------
// A valid generic pair must not let an invalid id pair through, and the
// two pairs must not contradict each other.
expect('tx: cash withdrawal with both pairs, consistent', await tx('m1', { type: 'transfer', account: 'mpesa', toAccount: 'cash', accountId: 'mpesa-sim2', toAccountId: 'cash', simSlot: 1, fee: 29 }), true);
expect('tx: generic pair ok but same account id on both sides', await tx('m2', { type: 'transfer', account: 'mpesa', toAccount: 'cash', accountId: 'mpesa-sim1', toAccountId: 'mpesa-sim1' }), false);
expect('tx: generic pair ok but only accountId', await tx('m3', { type: 'transfer', account: 'mpesa', toAccount: 'cash', accountId: 'mpesa-sim1' }), false);
expect('tx: generic pair ok but only toAccountId', await tx('m4', { type: 'transfer', account: 'mpesa', toAccount: 'cash', toAccountId: 'cash' }), false);
expect('tx: ids differ but generic pair is the same account', await tx('m5', { type: 'transfer', account: 'mpesa', toAccount: 'mpesa', accountId: 'mpesa-sim1', toAccountId: 'mpesa-sim2' }), false);
expect('tx: savings into the same account id', await tx('m6', { type: 'savings_contribution', category: 'savings', account: 'mpesa', accountId: 'ziidi-sim1', toAccountId: 'ziidi-sim1' }), false);
expect('tx: edit adds the same id on both sides to an older transfer', await write('nia', `${T}/t6`, { accountId: 'mpesa-sim1', toAccountId: 'mpesa-sim1' }), false);
expect('tx: edit adds consistent ids to an older transfer', await write('nia', `${T}/t6`, { accountId: 'mpesa-sim1', toAccountId: 'cash' }), true);

console.log(failures === 0 ? '\nAll accounts rules tests passed.' : `\n${failures} accounts rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
