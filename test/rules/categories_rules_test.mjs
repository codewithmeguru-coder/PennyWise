// Security rules for the user's own categories:
// users/{uid}/categories/{categoryId}. LOCAL Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/categories_rules_test.mjs"
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
  if (v === null) return { nullValue: null };
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

const both = ['createdAt', 'updatedAt'];

/**
 * Writes one document as [uid] (null = signed out). [stamp] lists fields set
 * to the server time; [create] requires the document not to exist.
 */
async function write(uid, path, data, { create = false, stamp = ['updatedAt'] } = {}) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      writes: await withClaim({ BASE, DOCS }, path, [{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: stamp.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' })),
        ...(create ? { currentDocument: { exists: false } } : { updateMask: { fieldPaths: Object.keys(data) } }),
      }]),
    }),
  });
  await res.text();
  return res.status;
}

/**
 * Replaces a whole document with no precondition (a plain `set`): if it
 * exists, the rules judge it as an update of that document.
 */
async function replace(uid, path, data, stamp = both) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      writes: await withClaim({ BASE, DOCS }, path, [{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: stamp.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' })),
      }]),
    }),
  });
  await res.text();
  return res.status;
}

/** One string field of a document, read as [uid]. */
async function field(uid, path, name) {
  const res = await fetch(`${BASE}/${path}`, { headers: headers(uid) });
  const body = await res.json();
  return body.fields?.[name]?.stringValue;
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

async function list(uid, owner) {
  const res = await fetch(`${BASE}/users/${owner}/categories`, { headers: headers(uid) });
  await res.text();
  return res.status;
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

const C = 'users/dina/categories';
const pets = { name: 'Pets', type: 'expense', icon: 'pets', active: true };
const make = (id, data) => write('dina', `${C}/${id}`, data, { create: true, stamp: both });

// ---- Owner ---------------------------------------------------------------------
expect('owner adds an expense category', await make('c_petsabcdef', pets), true);
expect('owner adds an income category', await make('c_rentincome', { name: 'Rent income', type: 'income', icon: 'home', active: true }), true);
expect('owner reads it', await read('dina', `${C}/c_petsabcdef`), true);
expect('owner lists categories', await list('dina', 'dina'), true);
expect('owner renames it (id unchanged)', await write('dina', `${C}/c_petsabcdef`, { name: 'Pet care' }), true);
expect('owner changes the icon', await write('dina', `${C}/c_petsabcdef`, { icon: 'medical' }), true);
expect('owner deactivates it', await write('dina', `${C}/c_petsabcdef`, { active: false }), true);
expect('owner reactivates it', await write('dina', `${C}/c_petsabcdef`, { active: true }), true);

// ---- Creating at an id that already exists ------------------------------------
// The app creates only after checking the id is free; these prove the rules
// also refuse to replace an existing category with a "new" one.
expect('new category over an existing id (fresh createdAt)', await replace('dina', `${C}/c_petsabcdef`, { name: 'Imposter', type: 'expense', icon: 'label', active: true }), false);
expect('new category over an existing id, other type', await replace('dina', `${C}/c_petsabcdef`, { name: 'Imposter', type: 'income', icon: 'label', active: true }), false);
expect('new category over an existing id without createdAt', await replace('dina', `${C}/c_petsabcdef`, { name: 'Imposter', type: 'expense', icon: 'label', active: true }, ['updatedAt']), false);
const createOver = await make('c_petsabcdef', { name: 'Imposter', type: 'expense', icon: 'label', active: true });
check(`create-only write over an existing id fails (HTTP ${createOver})`, createOver !== 200);
check('the existing category is unchanged', (await field('dina', `${C}/c_petsabcdef`, 'name')) === 'Pet care');

// ---- Ids ----------------------------------------------------------------------------
expect('built-in style id', await make('food', pets), false);
expect('id without the c_ prefix', await make('xpetsabcdef', pets), false);
expect('id with digits', await make('c_pets12345', pets), false);
expect('id with capitals', await make('c_PetsAbcdef', pets), false);
expect('id too short', await make('c_abc', pets), false);
expect('id too long', await make(`c_${'a'.repeat(31)}`, pets), false);

// ---- Fields ---------------------------------------------------------------------------
expect('empty name', await make('c_emptyname', { ...pets, name: '' }), false);
expect('31-character name', await make('c_longname', { ...pets, name: 'x'.repeat(31) }), false);
expect('name not text', await make('c_numbername', { ...pets, name: 5 }), false);
expect('type transfer', await make('c_typetransfer', { ...pets, type: 'transfer' }), false);
expect('bad icon key', await make('c_badicon', { ...pets, icon: 'Pets!' }), false);
expect('active not a bool', await make('c_badactive', { ...pets, active: 'yes' }), false);
expect('missing icon', await make('c_noicon', { name: 'X', type: 'expense', active: true }), false);
expect('extra field', await make('c_extrafield', { ...pets, color: 'red' }), false);
expect('createdAt set by the phone', await write('dina', `${C}/c_clientstamp`, { ...pets, createdAt: new Date('2026-01-01T00:00:00Z') }, { create: true, stamp: ['updatedAt'] }), false);
expect('update changing the type', await write('dina', `${C}/c_petsabcdef`, { type: 'income' }), false);
expect('update changing createdAt', await write('dina', `${C}/c_petsabcdef`, { createdAt: new Date('2020-01-01T00:00:00Z') }), false);
expect('update with a phone-set updatedAt', await write('dina', `${C}/c_petsabcdef`, { name: 'X', updatedAt: new Date('2026-01-01T00:00:00Z') }, { stamp: [] }), false);
expect('update to an empty name', await write('dina', `${C}/c_petsabcdef`, { name: '' }), false);

// ---- No delete, ever ------------------------------------------------------------------
expect('owner deletes it', await remove('dina', `${C}/c_petsabcdef`), false);
expect('it is still there', await read('dina', `${C}/c_petsabcdef`), true);

// ---- Other users and signed out ---------------------------------------------------------
expect('other user reads it', await read('mallory', `${C}/c_petsabcdef`), false);
expect('other user lists them', await list('mallory', 'dina'), false);
expect('other user renames it', await write('mallory', `${C}/c_petsabcdef`, { name: 'Hacked' }), false);
expect('other user adds one for dina', await write('mallory', `${C}/c_malloryadds`, pets, { create: true, stamp: both }), false);
expect('other user deletes it', await remove('mallory', `${C}/c_petsabcdef`), false);
expect('signed out reads it', await read(null, `${C}/c_petsabcdef`), false);
expect('signed out lists them', await list(null, 'dina'), false);
expect('signed out renames it', await write(null, `${C}/c_petsabcdef`, { name: 'x' }), false);
expect('signed out deletes it', await remove(null, `${C}/c_petsabcdef`), false);

// ---- Other collections accept custom ids, unchanged ---------------------------------------
expect('a transaction may use the custom id', await write('dina', 'users/dina/transactions/t-custom', { amount: 300, type: 'expense', category: 'c_petsabcdef', description: 'Vet', date: new Date('2026-10-20T10:00:00Z') }, { create: true, stamp: both }), true);
expect('a category limit may use the custom id', await write('dina', 'users/dina/categoryBudgets/2026-10_c_petsabcdef', { month: '2026-10', categoryId: 'c_petsabcdef', limit: 2000 }, { create: true }), true);

console.log(failures === 0 ? '\nAll category rules tests passed.' : `\n${failures} category rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
