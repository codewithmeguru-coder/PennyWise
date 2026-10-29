// Security rules for the user's own profile photo:
// users/{uid}/private/avatar. LOCAL Firestore emulator only:
//
//   firebase emulators:exec --only firestore --project demo-pennywise "node test/rules/avatar_rules_test.mjs"
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

/** Replaces a whole document (a plain `set`), [stamp] set to server time. */
async function set(uid, path, data, stamp = ['updatedAt']) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: headers(uid),
    body: JSON.stringify({
      writes: [{
        update: { name: `${DOCS}/${path}`, fields: fields(data) },
        updateTransforms: stamp.map((f) => ({ fieldPath: f, setToServerValue: 'REQUEST_TIME' })),
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

// Real format headers, padded to a size.
const jpeg = (bytes) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(bytes - 4, 7)]).toString('base64');
const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(200, 1)]).toString('base64');
const webp = Buffer.concat([Buffer.from('RIFF'), Buffer.from([0, 0, 0, 0]), Buffer.from('WEBP'), Buffer.alloc(200, 2)]).toString('base64');
const gif = Buffer.concat([Buffer.from('GIF89a'), Buffer.alloc(200, 3)]).toString('base64');
// A real 1×1 lossless WebP, and RIFF files that are not WebP.
const realWebp = 'UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==';
const riff = (kind) => Buffer.concat([Buffer.from('RIFF'), Buffer.from([0x24, 0, 0, 0]), Buffer.from(kind), Buffer.alloc(200, 5)]).toString('base64');
const wav = riff('WAVEfmt ');
const avi = riff('AVI LIST');

const A = 'users/pia/private/avatar';

// ---- Owner -------------------------------------------------------------------
expect('owner saves a JPEG', await set('pia', A, { imageBase64: jpeg(30000) }), true);
expect('owner reads it', await read('pia', A), true);
expect('owner replaces it with a PNG', await set('pia', A, { imageBase64: png }), true);
expect('owner replaces it with a WebP', await set('pia', A, { imageBase64: webp }), true);
expect('owner saves a real 1×1 WebP file', await set('pia', A, { imageBase64: realWebp }), true);
expect('owner saves exactly 250 KB', await set('pia', A, { imageBase64: jpeg(250 * 1024) }), true);

// ---- Content type and size ---------------------------------------------------------
expect('a GIF', await set('pia', A, { imageBase64: gif }), false);
expect('a WAV (RIFF, not WebP)', await set('pia', A, { imageBase64: wav }), false);
expect('an AVI (RIFF, not WebP)', await set('pia', A, { imageBase64: avi }), false);
expect('text that is not base64', await set('pia', A, { imageBase64: '/9j/not base64!' }), false);
expect('an empty photo', await set('pia', A, { imageBase64: '' }), false);
expect('over 250 KB', await set('pia', A, { imageBase64: jpeg(250 * 1024 + 3) }), false);
expect('a number instead of text', await set('pia', A, { imageBase64: 5 }), false);
expect('an extra field', await set('pia', A, { imageBase64: png, caption: 'me' }), false);
expect('missing photo', await set('pia', A, {}), false);
expect('updatedAt set by the phone', await set('pia', A, { imageBase64: png, updatedAt: new Date('2026-01-01T00:00:00Z') }, []), false);
expect('another document under private/', await set('pia', 'users/pia/private/other', { imageBase64: png }), false);
expect('a photo in the profile document itself', await set('pia', 'users/pia', { imageBase64: png }), false);

// ---- Other users and signed out --------------------------------------------------------
expect('other user reads it', await read('mallory', A), false);
expect('other user replaces it', await set('mallory', A, { imageBase64: png }), false);
expect('other user deletes it', await remove('mallory', A), false);
expect('other user saves one for pia', await set('mallory', 'users/pia/private/avatar', { imageBase64: jpeg(100) }), false);
expect('signed out reads it', await read(null, A), false);
expect('signed out replaces it', await set(null, A, { imageBase64: png }), false);
expect('signed out deletes it', await remove(null, A), false);

// ---- Remove --------------------------------------------------------------------------------
expect('owner removes it', await remove('pia', A), true);

console.log(failures === 0 ? '\nAll avatar rules tests passed.' : `\n${failures} avatar rules test(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
