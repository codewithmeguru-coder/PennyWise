// Security rules for "Fix moves between your SIMs": the exact writes the
// fix and its Undo make, under the current (unchanged) rules. LOCAL
// Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/move_fix_rules_test.mjs"
//
// The "demo-" project id keeps the emulator from ever reaching a real
// project. No npm packages: plain REST calls with unsigned emulator tokens.

import { withClaim } from './limit.mjs';
const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT = process.env.GCLOUD_PROJECT || 'demo-pennywise';
const DOCS = `projects/${PROJECT}/databases/(default)/documents`;
const BASE = `http://${HOST}/v1/${DOCS}`;
// Every commit carries the daily and edit claims the app makes.
import { autoClaim } from './limit.mjs';
autoClaim({ BASE, DOCS });

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
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  if (v && typeof v === 'object') return { mapValue: { fields: fields(v) } };
  throw new Error(`unsupported ${v}`);
}
const fields = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, value(v)]));
const headers = (uid) => ({
  'Content-Type': 'application/json',
  ...(uid ? { Authorization: `Bearer ${token(uid)}` } : {}),
});

/** Writes one document; uid null = signed out. Returns the HTTP status. */
async function write(uid, path, data, { create = false, transforms = [], mask } = {}) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      writes: await (create ? (w) => withClaim({ BASE, DOCS }, path, w) : async (w) => w)([{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: [
          ...(create ? [{ fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' }] : []),
          { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
          ...transforms.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' })),
        ],
        ...(create ? { currentDocument: { exists: false } } : { updateMask: { fieldPaths: mask ?? Object.keys(data) } }),
      }]),
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

async function groupQuery(uid, collectionId) {
  const res = await fetch(`${BASE}:runQuery`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({ structuredQuery: { from: [{ collectionId, allDescendants: true }] } }),
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

const day = new Date('2026-09-14T06:55:00Z');
const T = 'users/alice/transactions';
// As saved by the older import: no account, SIM or fee.
const old = (code, type, amount, category) => ({ amount, type, category, description: 'Item', date: day, source: 'mpesa', reference: code, smsText: 'x' });
const MASK = ['type', 'category', 'account', 'toAccount', 'accountId', 'toAccountId', 'simSlot', 'fee', 'reclassifiedFrom'];
const at = { transforms: ['reclassifiedFrom.at'] };

expect('setup: SIM-to-SIM move saved as an expense', await write('alice', `${T}/mpesa_UMV0000001`, old('UMV0000001', 'expense', 8000, 'uncategorized'), { create: true }), true);
expect('setup: the receiving side saved as income', await write('alice', `${T}/mpesa_UMV0000002`, old('UMV0000002', 'income', 100, 'money_received'), { create: true }), true);
expect('setup: cash withdrawal saved as an expense', await write('alice', `${T}/mpesa_UMV0000003`, old('UMV0000003', 'expense', 1250, 'cash_withdrawal'), { create: true }), true);
expect('setup: one already on SIM 2 with its fee', await write('alice', `${T}/mpesa_UMV0000004`, { ...old('UMV0000004', 'expense', 800, 'uncategorized'), account: 'mpesa', accountId: 'mpesa-sim2', simSlot: 1, fee: 13 }, { create: true }), true);

// ---- The fix -------------------------------------------------------------
const between = (from, to, slot, was, extra = {}) => ({ type: 'transfer', category: 'transfer', account: 'mpesa', accountId: from, toAccountId: to, simSlot: slot, reclassifiedFrom: was, ...extra });
expect('deny: SIM-to-SIM with toAccount mpesa on both sides', await write('alice', `${T}/mpesa_UMV0000001`, between('mpesa-sim2', 'mpesa-sim1', 1, { type: 'expense', category: 'uncategorized' }, { toAccount: 'mpesa' }), { ...at, mask: MASK }), false);
expect('deny: marker with a back-dated time', await write('alice', `${T}/mpesa_UMV0000001`, between('mpesa-sim2', 'mpesa-sim1', 1, { type: 'expense', category: 'uncategorized', at: day }), { mask: MASK }), false);
expect('deny: other user applies the fix', await write('mallory', `${T}/mpesa_UMV0000001`, between('mpesa-sim2', 'mpesa-sim1', 1, { type: 'expense', category: 'uncategorized' }, { fee: 90 }), { ...at, mask: MASK }), false);
expect('fix: SIM 2 -> SIM 1, ids only, fee added, marker now', await write('alice', `${T}/mpesa_UMV0000001`, between('mpesa-sim2', 'mpesa-sim1', 1, { type: 'expense', category: 'uncategorized' }, { fee: 90 }), { ...at, mask: MASK }), true);
expect('fix: income side, SIM 1 -> SIM 2, no fee', await write('alice', `${T}/mpesa_UMV0000002`, between('mpesa-sim1', 'mpesa-sim2', 0, { type: 'income', category: 'money_received' }), { ...at, mask: MASK }), true);
expect('fix: withdrawal SIM 1 M-Pesa -> Cash with its fee', await write('alice', `${T}/mpesa_UMV0000003`, between('mpesa-sim1', 'cash', 0, { type: 'expense', category: 'cash_withdrawal' }, { toAccount: 'cash', fee: 29 }), { ...at, mask: MASK }), true);
expect('fix: fee already there is kept', await write('alice', `${T}/mpesa_UMV0000004`, between('mpesa-sim2', 'mpesa-sim1', 1, { type: 'expense', category: 'uncategorized' }, { fee: 13 }), { ...at, mask: MASK }), true);
expect('deny: the marker changed again later with an old time', await write('alice', `${T}/mpesa_UMV0000001`, { reclassifiedFrom: { type: 'income', category: 'x', at: day } }), false);

// ---- Undo -----------------------------------------------------------------
expect('undo: back to an expense with no account, SIM or fee', await write('alice', `${T}/mpesa_UMV0000001`, { type: 'expense', category: 'uncategorized' }, { mask: MASK }), true);
expect('undo: income side back', await write('alice', `${T}/mpesa_UMV0000002`, { type: 'income', category: 'money_received' }, { mask: MASK }), true);
expect('undo: withdrawal back', await write('alice', `${T}/mpesa_UMV0000003`, { type: 'expense', category: 'cash_withdrawal' }, { mask: MASK }), true);
expect('undo: keeps what it had before (account, SIM 2, fee 13)', await write('alice', `${T}/mpesa_UMV0000004`, { type: 'expense', category: 'uncategorized', account: 'mpesa', accountId: 'mpesa-sim2', simSlot: 1, fee: 13 }, { mask: MASK }), true);
expect('deny: an expense keeping toAccountId (Undo must remove it)', await write('alice', `${T}/mpesa_UMV0000001`, { type: 'expense', category: 'uncategorized', accountId: 'mpesa-sim2', toAccountId: 'mpesa-sim1' }, { mask: MASK }), false);

console.log(failures === 0 ? '\nAll move fix rules tests passed.' : `\n${failures} move fix rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
