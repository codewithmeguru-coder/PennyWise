// Phase 3 security-rules tests (learned category rules, new transaction
// fields, the history-fix undo marker). LOCAL Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/phase3_rules_test.mjs"
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
      writes: [{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: [
          ...(create ? [{ fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' }] : []),
          { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
          ...transforms.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' })),
        ],
        ...(create ? { currentDocument: { exists: false } } : { updateMask: { fieldPaths: mask ?? Object.keys(data) } }),
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

const day = new Date('2026-10-09T12:00:00Z');
const rule = (key, extra = {}) => ({ merchantKey: key, categoryId: 'shopping', type: 'expense', count: 1, label: 'Lilies Supermarket', ...extra });
const smsTx = { amount: 1, type: 'expense', category: 'uncategorized', description: 'Ziidi', date: day, source: 'mpesa', reference: 'UIEHK3T4AS', smsText: 'x' };
const manualTx = { amount: 500, type: 'expense', category: 'food', description: 'Lunch', date: day };
const R = 'users/alice/categoryRules';
const T = 'users/alice/transactions';

// ---- Learned category rules ----------------------------------------------
expect('owner creates a rule', await write('alice', `${R}/OUT:LILIES_SUPERMARKET`, rule('OUT:LILIES_SUPERMARKET'), { create: true }), true);
expect('owner reads own rule', await read('alice', `${R}/OUT:LILIES_SUPERMARKET`), true);
expect('owner updates rule (count + category)', await write('alice', `${R}/OUT:LILIES_SUPERMARKET`, { categoryId: 'food', count: 2 }), true);
expect('rule with a Paybill account key', await write('alice', `${R}/OUT:KPLC_PREPAID:54XXXXX789`, rule('OUT:KPLC_PREPAID:54XXXXX789', { categoryId: 'bills' }), { create: true }), true);
expect('signed out: read rule', await read(null, `${R}/OUT:LILIES_SUPERMARKET`), false);
expect('signed out: create rule', await write(null, `${R}/OUT:X`, rule('OUT:X'), { create: true }), false);
expect('other user: read your rule', await read('mallory', `${R}/OUT:LILIES_SUPERMARKET`), false);
expect('other user: create rule in your account', await write('mallory', `${R}/OUT:EVIL`, rule('OUT:EVIL'), { create: true }), false);
expect('other user: change your rule', await write('mallory', `${R}/OUT:LILIES_SUPERMARKET`, { categoryId: 'bills' }), false);
expect('other user: delete your rule', await remove('mallory', `${R}/OUT:LILIES_SUPERMARKET`), false);
expect('query everyone\'s rules (collection group)', await groupQuery('alice', 'categoryRules'), false);
expect('malformed: extra field', await write('alice', `${R}/OUT:A`, rule('OUT:A', { secret: 'x' }), { create: true }), false);
expect('malformed: id does not match merchantKey', await write('alice', `${R}/OUT:A`, rule('OUT:B'), { create: true }), false);
expect('malformed: lower-case / bad id', await write('alice', `${R}/out:naivas`, rule('out:naivas'), { create: true }), false);
expect('malformed: id too long', await write('alice', `${R}/OUT:${'A'.repeat(130)}`, rule(`OUT:${'A'.repeat(130)}`), { create: true }), false);
expect('malformed: count 0', await write('alice', `${R}/OUT:C`, rule('OUT:C', { count: 0 }), { create: true }), false);
expect('malformed: count not an integer', await write('alice', `${R}/OUT:C`, rule('OUT:C', { count: 1.5 }), { create: true }), false);
expect('malformed: unknown type', await write('alice', `${R}/OUT:C`, rule('OUT:C', { type: 'gift' }), { create: true }), false);
expect('malformed: label too long', await write('alice', `${R}/OUT:C`, rule('OUT:C', { label: 'x'.repeat(101) }), { create: true }), false);
expect('malformed: changing createdAt', await write('alice', `${R}/OUT:LILIES_SUPERMARKET`, { createdAt: new Date('2020-01-01T00:00:00Z') }), false);
expect('owner deletes own rule', await remove('alice', `${R}/OUT:KPLC_PREPAID:54XXXXX789`), true);

// ---- New optional transaction fields -------------------------------------
expect('owner: transaction with categoryStatus + channel', await write('alice', `${T}/p3-t1`, { ...manualTx, categoryStatus: 'suggested', channel: 'till' }, { create: true }), true);
expect('malformed: unknown categoryStatus', await write('alice', `${T}/p3-t2`, { ...manualTx, categoryStatus: 'maybe' }, { create: true }), false);
expect('malformed: unknown channel', await write('alice', `${T}/p3-t3`, { ...manualTx, channel: 'crypto' }, { create: true }), false);
expect('other user: read your transaction', await read('mallory', `${T}/p3-t1`), false);
expect('signed out: read your transaction', await read(null, `${T}/p3-t1`), false);

// ---- History-fix undo marker (reclassifiedFrom) --------------------------
await write('alice', `${T}/mpesa_UIEHK3T4AS`, smsTx, { create: true });
await write('alice', `${T}/p3-manual1`, manualTx, { create: true });
const fix = { type: 'savings_contribution', category: 'savings', account: 'mpesa', reclassifiedFrom: { type: 'expense', category: 'uncategorized' } };
expect('marker cannot be created with a new document', await write('alice', `${T}/p3-new1`, { ...smsTx, reclassifiedFrom: { type: 'expense', category: 'x', at: day } }, { create: true }), false);
expect('fix: marker with at = now', await write('alice', `${T}/mpesa_UIEHK3T4AS`, fix, { transforms: ['reclassifiedFrom.at'], mask: ['type', 'category', 'account', 'reclassifiedFrom'] }), true);
expect('later edit keeps the same marker', await write('alice', `${T}/mpesa_UIEHK3T4AS`, { description: 'Ziidi savings' }), true);
expect('malformed: marker changed with a back-dated time', await write('alice', `${T}/mpesa_UIEHK3T4AS`, { reclassifiedFrom: { type: 'income', category: 'x', at: day } }), false);
expect('malformed: marker on a manual entry', await write('alice', `${T}/p3-manual1`, { reclassifiedFrom: { type: 'expense', category: 'food' } }, { transforms: ['reclassifiedFrom.at'] }), false);
expect('malformed: marker with an extra key', await write('alice', `${T}/mpesa_UIEHK3T4AS`, { reclassifiedFrom: { type: 'expense', category: 'x', note: 'y' } }, { transforms: ['reclassifiedFrom.at'] }), false);
expect('malformed: marker with a bad old type', await write('alice', `${T}/mpesa_UIEHK3T4AS`, { reclassifiedFrom: { type: 'transfer', category: 'x' } }, { transforms: ['reclassifiedFrom.at'] }), false);
expect('other user: apply the fix to your record', await write('mallory', `${T}/mpesa_UIEHK3T4AS`, fix, { transforms: ['reclassifiedFrom.at'], mask: ['type', 'category', 'account', 'reclassifiedFrom'] }), false);
expect('undo: restore type/category and remove marker', await write('alice', `${T}/mpesa_UIEHK3T4AS`, { type: 'expense', category: 'uncategorized' }, { mask: ['type', 'category', 'account', 'reclassifiedFrom'] }), true);

console.log(failures === 0 ? '\nAll Phase 3 rules tests passed.' : `\n${failures} Phase 3 rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
