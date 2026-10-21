// Security-rules tests for users/{uid}/transactions, run against the LOCAL
// Firestore emulator only (never the live project):
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/transactions_rules_test.mjs"
//
// The "demo-" project id keeps the emulator from ever reaching a real
// project. If port 8080 is busy, run it from a folder whose firebase.json
// sets another emulator port (the script reads FIRESTORE_EMULATOR_HOST).
//
// No npm packages needed: it talks to the emulator's REST API with unsigned
// test tokens, which only the emulator accepts.

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
    firebase: { sign_in_provider: 'password' },
  })}.`;

// Plain JS values -> Firestore REST values.
function value(v) {
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  throw new Error(`unsupported ${v}`);
}
const fields = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, value(v)]));

let n = 0;
/** Creates users/{owner}/transactions/{id} as [uid]; returns the HTTP status. */
async function create(data, { uid = 'alice', owner = uid } = {}) {
  const name = `${DOCS}/users/${owner}/transactions/t${++n}`;
  return write(uid, name, data, { exists: false });
}

async function write(uid, name, data, currentDocument) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token(uid)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      writes: [{
        update: { name, fields: fields(data) },
        updateTransforms: [
          ...(currentDocument.exists === false ? [{ fieldPath: 'createdAt', setToServerValue: 'REQUEST_TIME' }] : []),
          { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
        ],
        ...(currentDocument.exists === false ? { currentDocument } : { updateMask: { fieldPaths: Object.keys(data) } }),
      }],
    }),
  });
  await res.text();
  return res.status;
}

const base = { amount: 500, category: 'food', description: 'Lunch', date: new Date('2026-10-01T12:00:00Z') };
let failures = 0;
async function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

const cases = [
  // Older documents: exactly what the previous app version writes.
  ['legacy income, no new fields', { ...base, type: 'income', category: 'salary' }, true],
  ['legacy expense from SMS', { ...base, type: 'expense', source: 'mpesa', reference: 'UJ1ABC2DEF', smsText: 'x' }, true],
  // New types.
  ['expense with account and fee', { ...base, type: 'expense', account: 'mpesa', fee: 7 }, true],
  ['cash withdrawal transfer M-Pesa to Cash with fee', { ...base, type: 'transfer', category: 'transfer', account: 'mpesa', toAccount: 'cash', fee: 29 }, true],
  ['savings contribution', { ...base, type: 'savings_contribution', category: 'savings', account: 'mpesa' }, true],
  ['savings withdrawal', { ...base, type: 'savings_withdrawal', category: 'savings_withdrawal', account: 'mpesa' }, true],
  ['refund linked to a purchase', { ...base, type: 'refund', account: 'mpesa', refundOf: 't1' }, true],
  ['debt repayment with interest', { ...base, type: 'debt_repayment', category: 'debt_repayment', account: 'mpesa', interest: 25 }, true],
  ['debt repayment, interest unknown', { ...base, type: 'debt_repayment', category: 'debt_repayment' }, true],
  // Rejected.
  ['unknown type', { ...base, type: 'gift' }, false],
  ['transfer without toAccount', { ...base, type: 'transfer', category: 'transfer', account: 'mpesa' }, false],
  ['transfer to the same account', { ...base, type: 'transfer', category: 'transfer', account: 'cash', toAccount: 'cash' }, false],
  ['transfer into savings account', { ...base, type: 'transfer', category: 'transfer', account: 'mpesa', toAccount: 'savings' }, false],
  ['toAccount on an expense', { ...base, type: 'expense', account: 'mpesa', toAccount: 'cash' }, false],
  ['unknown account', { ...base, type: 'expense', account: 'paypal' }, false],
  ['zero fee', { ...base, type: 'expense', fee: 0 }, false],
  ['interest above the amount', { ...base, type: 'debt_repayment', category: 'debt_repayment', interest: 600 }, false],
  ['interest on an expense', { ...base, type: 'expense', interest: 5 }, false],
  ['refundOf on an expense', { ...base, type: 'expense', refundOf: 't1' }, false],
  ['unexpected field', { ...base, type: 'expense', password: 'x' }, false],
];

for (const [label, data, ok] of cases) await expect(label, await create(data), ok);
await expect("writing to another user's transactions", await create({ ...base, type: 'income' }, { uid: 'mallory', owner: 'alice' }), false);

// Editing an older document to add an account (what the new form does).
const legacy = `${DOCS}/users/alice/transactions/legacy`;
await write('alice', legacy, { ...base, type: 'expense' }, { exists: false });
await expect('updating a legacy expense to add an account', await write('alice', legacy, { account: 'cash' }, {}), true);
await expect('turning it into a transfer without toAccount', await write('alice', legacy, { type: 'transfer' }, {}), false);

console.log(failures === 0 ? '\nAll rules tests passed.' : `\n${failures} rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
