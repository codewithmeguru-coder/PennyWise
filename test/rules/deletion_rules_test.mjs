// Security rules for account deletion: accounts, balance history and
// categories can be deleted only by their owner, and only after that owner
// has recorded users/{uid}/deletionRequest/current. LOCAL emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/deletion_rules_test.mjs"

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
// The emulator's admin token: seeds data without the rules.
const headers = (uid) => ({
  'Content-Type': 'application/json',
  Authorization: `Bearer ${uid === 'ADMIN' ? 'owner' : token(uid)}`,
});

async function commit(uid, write) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST', headers: headers(uid), body: JSON.stringify({ writes: [write] }),
  });
  await res.text();
  return res.status;
}
const seed = (path) => commit('ADMIN', {
  update: { name: `${DOCS}/${path}`, fields: { name: { stringValue: 'x' } } },
});
const remove = (uid, path) => commit(uid, { delete: `${DOCS}/${path}` });
const request = (uid, owner, extra = {}) => commit(uid, {
  update: { name: `${DOCS}/users/${owner}/deletionRequest/current`, fields: extra },
  updateTransforms: [{ fieldPath: 'requestedAt', setToServerValue: 'REQUEST_TIME' }],
});

let failures = 0;
function expect(label, status, ok) {
  const passed = ok ? status === 200 : status === 403;
  if (!passed) failures++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${ok ? 'allow' : 'deny '}  ${label} (HTTP ${status})`);
}

const kept = ['accounts/mpesa-sim1', 'balanceAnchors/a1', 'categories/c_petsabcdef'];
for (const p of kept) await seed(`users/dee/${p}`);

// Before a deletion request: these are kept, even from the owner.
for (const p of kept) expect(`owner deletes ${p} without a request`, await remove('dee', `users/dee/${p}`), false);

// The request: only the owner, only "requestedAt" stamped now.
expect('another user records a request for dee', await request('mallory', 'dee'), false);
expect('a request with extra fields', await request('dee', 'dee', { note: { stringValue: 'x' } }), false);
expect('owner records the request', await request('dee', 'dee'), true);

// After it: never another user; the owner may.
for (const p of kept) expect(`another user deletes ${p}`, await remove('mallory', `users/dee/${p}`), false);
for (const p of kept) expect(`owner deletes ${p}`, await remove('dee', `users/dee/${p}`), true);
expect('owner removes the request last', await remove('dee', 'users/dee/deletionRequest/current'), true);

console.log(failures === 0 ? '\nAll deletion rules tests passed.' : `\n${failures} deletion rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
