// Security-rules tests for users/{uid}/balanceAnchors (the history of each
// account's starting balance). LOCAL Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/anchors_rules_test.mjs"
//
// The "demo-" project id keeps the emulator from ever reaching a real
// project. No npm packages: plain REST calls with unsigned emulator tokens.

const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT = process.env.GCLOUD_PROJECT || 'demo-pennywise';
if (!PROJECT.startsWith('demo-')) throw new Error('Emulator demo project only');
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

async function commit(uid, writes) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST', headers: headers(uid), body: JSON.stringify({ writes }),
  });
  await res.text();
  return res.status;
}
const stamps = (list) => list.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' }));
// A create, with the given fields stamped by the server.
const create = (path, data, stamp = ['createdAt']) => ({
  update: { name: `${DOCS}/${path}`, fields: fields(data) },
  updateTransforms: stamps(stamp),
  currentDocument: { exists: false },
});
// An update of [keys] (default: [data]'s keys); a key in [keys] but not in
// [data] is deleted.
const update = (path, data, stamp = [], keys = Object.keys(data)) => ({
  update: { name: `${DOCS}/${path}`, fields: fields(data) },
  updateMask: { fieldPaths: keys },
  updateTransforms: stamps(stamp),
});
// The account's starting balance, as the app writes it (null = cleared).
const setOpening = (path, amount, at) => amount === null
  ? update(path, {}, ['updatedAt'], ['openingBalance', 'openingDate'])
  : update(path, { openingBalance: amount, openingDate: at }, ['updatedAt']);
async function read(uid, path) {
  const res = await fetch(`${BASE}/${path}`, { headers: headers(uid) });
  await res.text();
  return res.status;
}
async function field(uid, path, name) {
  const res = await fetch(`${BASE}/${path}`, { headers: headers(uid) });
  const doc = await res.json();
  const f = doc.fields?.[name];
  if (f === undefined) return undefined;
  if ('doubleValue' in f) return f.doubleValue;
  if ('integerValue' in f) return Number(f.integerValue);
  return f.timestampValue;
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
function check(label, ok) {
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  check  ${label}`);
}

const A = 'users/nia/accounts';
const N = 'users/nia/balanceAnchors';
const SIM = `${A}/mpesa-sim1`;
const day = new Date('2026-10-22T09:00:00Z');
const later = new Date('2026-10-23T09:00:00Z');
const base = { uid: 'nia', accountId: 'mpesa-sim1', currency: 'KES', reason: 'Starting balances', undone: false };
const account = (name, kind, provider, extra = {}) =>
  ({ name, kind, provider, active: true, order: 0, ...extra });

// An account to anchor (the accounts suite covers accounts themselves).
await commit('nia', [create(SIM, account('SIM 1 M-Pesa', 'mobile_money', 'safaricom', { simSlot: 0 }), ['createdAt', 'updatedAt'])]);
await commit('mallory', [create('users/mallory/accounts/mpesa-sim1', account('SIM 1 M-Pesa', 'mobile_money', 'safaricom', { simSlot: 0 }), ['createdAt', 'updatedAt'])]);

// ---- Create, always together with the account's change --------------------
expect('owner sets a starting balance with its record', await commit('nia', [
  setOpening(SIM, 1500.5, day),
  create(`${N}/a1`, { ...base, amount: 1500.5, effectiveAt: day }),
]), true);
expect('owner reads it', await read('nia', `${N}/a1`), true);
expect('owner changes it, recording the value it replaced', await commit('nia', [
  setOpening(SIM, 700, later),
  create(`${N}/a2`, { ...base, amount: 700, effectiveAt: later, previousAmount: 1500.5, previousEffectiveAt: day, reason: 'Used SMS balance' }),
]), true);
expect('owner clears it ("no starting balance")', await commit('nia', [
  setOpening(SIM, null),
  create(`${N}/a3`, { ...base, previousAmount: 700, previousEffectiveAt: later, reason: 'Edited' }),
]), true);
expect('owner sets it again', await commit('nia', [
  setOpening(SIM, 900, later),
  create(`${N}/a4`, { ...base, amount: 900, effectiveAt: later }),
]), true);

// ---- The record must match the account ------------------------------------
expect('record alone, claiming an amount the account doesn\'t hold', await commit('nia', [create(`${N}/r1`, { ...base, amount: 5, effectiveAt: later, previousAmount: 900, previousEffectiveAt: later })]), false);
expect('record with a wrong "previous" value', await commit('nia', [
  setOpening(SIM, 950, later),
  create(`${N}/r2`, { ...base, amount: 950, effectiveAt: later, previousAmount: 1, previousEffectiveAt: later }),
]), false);
expect('record leaving out the previous value', await commit('nia', [
  setOpening(SIM, 950, later),
  create(`${N}/r3`, { ...base, amount: 950, effectiveAt: later }),
]), false);
expect('record with the right amount but a different time', await commit('nia', [
  setOpening(SIM, 950, later),
  create(`${N}/r4`, { ...base, amount: 950, effectiveAt: day, previousAmount: 900, previousEffectiveAt: later }),
]), false);
check('after those rejections the account still holds 900', await field('nia', SIM, 'openingBalance') === 900);

// ---- A rejected write leaves nothing half-done ----------------------------
expect('account change + invalid record (wrong currency) in one commit', await commit('nia', [
  setOpening(SIM, 111, later),
  create(`${N}/r5`, { ...base, amount: 111, effectiveAt: later, previousAmount: 900, previousEffectiveAt: later, currency: 'USD' }),
]), false);
check('the account was not changed by it', await field('nia', SIM, 'openingBalance') === 900);
check('and no record was created', await read('nia', `${N}/r5`) === 404);

// ---- Every account type: created, then given its starting balance and record
// (as the app does; a new account and its first record in one request would
// need two new-record claims, see account_creation_rules_test.mjs) ----------
for (const [id, a, amount] of [
  ['equity-test', account('Equity', 'bank', 'equity'), 2500],
  ['cash-test', account('Cash', 'cash', 'none'), 300],
  ['ziidi-test', account('Ziidi (SIM 2)', 'savings', 'safaricom', { simSlot: 1, parentId: 'mpesa-sim2' }), 40],
  ['fuliza-test', account('Fuliza (SIM 2)', 'loan', 'safaricom', { simSlot: 1, parentId: 'mpesa-sim2' }), -180.57],
  ['hidden-test', account('Old line', 'mobile_money', 'safaricom', { active: false }), 0],
]) {
  const label = `${a.kind}${a.active ? '' : ' (hidden)'}`;
  expect(`${label}: new account`, await commit('nia', [
    create(`${A}/${id}`, a, ['createdAt', 'updatedAt']),
  ]), true);
  expect(`${label}: its starting balance and record`, await commit('nia', [
    setOpening(`${A}/${id}`, amount, day),
    create(`${N}/t-${id}`, { ...base, accountId: id, amount, effectiveAt: day }),
  ]), true);
}
expect('new account: a record claiming a previous value', await commit('nia', [
  create(`${A}/new-x`, { ...account('X', 'cash', 'none'), openingBalance: 1, openingDate: day }, ['createdAt', 'updatedAt']),
  create(`${N}/t-new-x`, { ...base, accountId: 'new-x', amount: 1, effectiveAt: day, previousAmount: 1, previousEffectiveAt: day }),
]), false);

// ---- Other users and signed out -------------------------------------------
const ok900 = { ...base, amount: 900, effectiveAt: later, previousAmount: 900, previousEffectiveAt: later };
expect('other user reads it', await read('mallory', `${N}/a1`), false);
expect('other user creates one in your history', await commit('mallory', [create(`${N}/m1`, { ...ok900, uid: 'mallory' })]), false);
expect('other user creates one claiming your uid', await commit('mallory', [create(`${N}/m2`, ok900)]), false);
expect('signed out reads it', await read(null, `${N}/a1`), false);
expect('signed out creates one', await commit(null, [create(`${N}/s1`, ok900)]), false);
expect('owner writes another user\'s uid into own record', await commit('nia', [create(`${N}/x1`, { ...ok900, uid: 'mallory' })]), false);
expect('owner anchors an account that does not exist', await commit('nia', [create(`${N}/x2`, { ...base, accountId: 'no-such-account' })]), false);
expect('owner anchors another user\'s account by a path trick', await commit('nia', [create(`${N}/x3`, { ...base, accountId: '../../mallory/accounts/mpesa-sim1' })]), false);

// ---- Malformed --------------------------------------------------------------
expect('wrong currency', await commit('nia', [create(`${N}/b1`, { ...ok900, currency: 'USD' })]), false);
expect('unknown reason', await commit('nia', [create(`${N}/b2`, { ...ok900, reason: 'Because' })]), false);
expect('amount without its time', await commit('nia', [create(`${N}/b3`, (({ effectiveAt, ...r }) => r)(ok900))]), false);
expect('previous amount without its time', await commit('nia', [create(`${N}/b4`, (({ previousEffectiveAt, ...r }) => r)(ok900))]), false);
expect('amount as text', await commit('nia', [create(`${N}/b5`, { ...ok900, amount: '900' })]), false);
expect('amount too large', await commit('nia', [create(`${N}/b6`, { ...ok900, amount: 2000000000 })]), false);
expect('effective time as text', await commit('nia', [create(`${N}/b7`, { ...ok900, effectiveAt: 'yesterday' })]), false);
expect('extra field', await commit('nia', [create(`${N}/b8`, { ...ok900, note: 'x' })]), false);
expect('missing accountId', await commit('nia', [create(`${N}/b9`, (({ accountId, ...r }) => r)(ok900))]), false);
expect('created already undone', await commit('nia', [create(`${N}/b10`, { ...ok900, undone: true }, ['createdAt', 'undoneAt'])]), false);
expect('created with undoneAt supplied', await commit('nia', [create(`${N}/b11`, ok900, ['createdAt', 'undoneAt'])]), false);
expect('createdAt chosen by the client', await commit('nia', [create(`${N}/b12`, { ...ok900, createdAt: day }, [])]), false);
expect('bad record id', await commit('nia', [create(`${N}/bad id!`, ok900)]), false);

// ---- History can't be edited or deleted -----------------------------------
expect('owner deletes a record', await remove('nia', `${N}/a1`), false);
expect('owner changes the amount', await commit('nia', [update(`${N}/a1`, { amount: 1 })]), false);
expect('owner changes the effective time', await commit('nia', [update(`${N}/a1`, { effectiveAt: new Date('2020-01-01T00:00:00Z') })]), false);
expect('owner changes the account', await commit('nia', [update(`${N}/a1`, { accountId: 'cash-test' })]), false);
expect('owner changes the uid', await commit('nia', [update(`${N}/a1`, { uid: 'mallory' })]), false);
expect('owner changes the reason', await commit('nia', [update(`${N}/a1`, { reason: 'Edited' })]), false);
expect('owner adds an unknown field', await commit('nia', [update(`${N}/a1`, { note: 'x' })]), false);
expect('other user deletes it', await remove('mallory', `${N}/a1`), false);

// ---- Undo ---------------------------------------------------------------------
// a4 set 900 (from nothing): its Undo clears the account again.
expect('old Undo of a2 while the account holds a later value', await commit('nia', [
  setOpening(SIM, 1500.5, day),
  update(`${N}/a2`, { undone: true }, ['undoneAt']),
]), false);
expect('Undo without restoring the account', await commit('nia', [update(`${N}/a4`, { undone: true }, ['undoneAt'])]), false);
expect('Undo restoring the wrong value', await commit('nia', [
  setOpening(SIM, 1, later),
  update(`${N}/a4`, { undone: true }, ['undoneAt']),
]), false);
expect('Undo with a back-dated time', await commit('nia', [
  setOpening(SIM, null),
  update(`${N}/a4`, { undone: true, undoneAt: day }),
]), false);
expect('Undo that also changes the amount', await commit('nia', [
  setOpening(SIM, null),
  update(`${N}/a4`, { undone: true, amount: 5 }, ['undoneAt']),
]), false);
expect('other user undoes it', await commit('mallory', [update(`${N}/a4`, { undone: true }, ['undoneAt'])]), false);
check('after those rejections the account still holds 900', await field('nia', SIM, 'openingBalance') === 900);
expect('owner undoes it, restoring the account in the same commit', await commit('nia', [
  setOpening(SIM, null),
  update(`${N}/a4`, { undone: true }, ['undoneAt']),
]), true);
check('the account is back to no starting balance', await field('nia', SIM, 'openingBalance') === undefined);
expect('Undo twice', await commit('nia', [update(`${N}/a4`, { undone: true }, ['undoneAt'])]), false);
expect('un-undo', await commit('nia', [update(`${N}/a4`, { undone: false })]), false);
expect('undone record still readable', await read('nia', `${N}/a4`), true);
expect('Undo of a loan record (negative = owed)', await commit('nia', [
  setOpening(`${A}/fuliza-test`, null),
  update(`${N}/t-fuliza-test`, { undone: true }, ['undoneAt']),
]), true);

// ---- Unrelated collections unchanged --------------------------------------
expect('owner still edits own account name alone', await commit('nia', [update(SIM, { name: 'Line 1' }, ['updatedAt'])]), true);
expect('other user still can\'t edit it', await commit('mallory', [update(SIM, { name: 'x' }, ['updatedAt'])]), false);
expect('no delete of accounts still', await remove('nia', SIM), false);

console.log(failures === 0 ? '\nAll anchor rules tests passed.' : `\n${failures} anchor rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
