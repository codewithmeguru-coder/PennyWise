// Shared by the rules tests. New transactions, learned categories, custom
// categories, accounts and balance history records must claim the owner's daily write counter in the same request
// (see claimsLimit in firestore.rules), and edits must claim the edit
// counter (claimsEdit). This builds those claims.

const GATED = /^users\/([^/]+)\/(transactions|categoryRules|categories|accounts|balanceAnchors)\/([^/]+)$/;

/** Path inside the user's tree, e.g. "transactions/t1", or null. */
export function gatedPath(path) {
  const m = GATED.exec(path);
  return m ? { owner: m[1], path: `${m[2]}/${m[3]}` } : null;
}

// Updates of these claim an edit ...
const EDITED = /^users\/([^/]+)\/(transactions|categoryRules|accounts|categories)\/([^/]+)$/;
// ... and so does every save of these (create or update).
const SAVED = /^users\/([^/]+)\/(budgets|categoryBudgets|private)\/([^/]+)$/;
const PROFILE = /^users\/([^/]+)$/;

/**
 * The counter path claimed by a write of [path] ("users/u/..."), given
 * whether the document already exists: { owner, counter, path } or null.
 */
export function claimFor(path, exists) {
  let m;
  if ((m = PROFILE.exec(path))) return { owner: m[1], counter: 'edits', path: 'profile' };
  if ((m = SAVED.exec(path))) return { owner: m[1], counter: 'edits', path: `${m[2]}/${m[3]}` };
  if (exists && (m = EDITED.exec(path))) return { owner: m[1], counter: 'edits', path: `${m[2]}/${m[3]}` };
  const g = !exists && gatedPath(path);
  return g ? { owner: g.owner, counter: 'daily', path: g.path } : null;
}

const utcDay = (ms) => Math.floor(ms / 86400000);

async function adminGet(url, rawFetch = fetch) {
  const res = await rawFetch(url, { headers: { Authorization: 'Bearer owner' } });
  const doc = res.ok ? await res.json() : null;
  if (!res.ok) await res.text().catch(() => {});
  return doc;
}

/**
 * The write that claims one from [owner]'s [counter] ("daily" or "edits")
 * for [path]: one more than today's count (read with the emulator's admin
 * access), or 1.
 */
export async function claimWrite({ BASE, DOCS }, owner, path, counter = 'daily', rawFetch = fetch) {
  const doc = await adminGet(`${BASE}/users/${owner}/limits/${counter}`, rawFetch);
  const at = doc?.fields?.at?.timestampValue;
  const count = Number(doc?.fields?.count?.integerValue ?? 0);
  const next = at && utcDay(Date.parse(at)) === utcDay(Date.now()) ? count + 1 : 1;
  return {
    update: {
      name: `${DOCS}/users/${owner}/limits/${counter}`,
      fields: { count: { integerValue: String(next) }, lastPath: { stringValue: path } },
    },
    updateTransforms: [{ fieldPath: 'at', setToServerValue: 'REQUEST_TIME' }],
  };
}

/** The edit claim for [path] ("transactions/t1", "profile", ...). */
export const claimEdit = (env, owner, path, rawFetch = fetch) =>
  claimWrite(env, owner, path, 'edits', rawFetch);

/** [writes] with the claim added when [docPath] needs one. */
export async function withClaim(env, docPath, writes) {
  const g = gatedPath(docPath);
  return g ? [await claimWrite(env, g.owner, g.path), ...writes] : writes;
}

/**
 * [writes] with every claim the app would make in the same request: one
 * daily claim for the first new gated document, one edit claim for the
 * first edit, unless the request already writes that counter. Deletes
 * claim nothing.
 */
export async function withAllClaims(env, writes, rawFetch = fetch) {
  const prefix = `${env.DOCS}/`;
  const written = new Set();
  for (const w of writes) {
    const m = w.update && /\/users\/[^/]+\/limits\/([^/]+)$/.exec(w.update.name);
    if (m) written.add(m[1]);
  }
  const claims = [];
  for (const w of writes) {
    if (!w.update || !w.update.name.startsWith(prefix)) continue;
    const path = w.update.name.slice(prefix.length);
    const exists = w.currentDocument?.exists === false
      ? false
      : (await adminGet(`${env.BASE}/${path}`, rawFetch)) != null;
    const c = claimFor(path, exists);
    if (!c || written.has(c.counter)) continue;
    written.add(c.counter);
    claims.push(await claimWrite(env, c.owner, c.path, c.counter, rawFetch));
  }
  return [...claims, ...writes];
}

/**
 * Makes every signed-in (non-admin) commit to the emulator carry the
 * claims the app makes (see withAllClaims), so tests about other rules
 * behave like the real app. The limit tests themselves don't use this.
 */
export function autoClaim(env) {
  const raw = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const auth = init.headers?.Authorization ?? '';
    if (String(url) === `${env.BASE}:commit` && init.method === 'POST' && auth !== 'Bearer owner' && init.body) {
      const body = JSON.parse(init.body);
      body.writes = await withAllClaims(env, body.writes ?? [], raw);
      init = { ...init, body: JSON.stringify(body) };
    }
    return raw(url, init);
  };
}
