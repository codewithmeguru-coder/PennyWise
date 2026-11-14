// The public privacy page (hosting/privacy, served at /privacy) and the
// policy it's built from (docs/play/privacy-policy.md):
//   node --test test/web/privacy_page_test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';

const read = (p) => readFile(new URL(p, import.meta.url), 'utf8');
const html = await read('../../hosting/privacy/index.html');
const md = (await read('../../docs/play/privacy-policy.md')).replace(/\r\n/g, '\n');

const pageText = html
  .replace(/<!--[\s\S]*?-->/g, ' ')
  .replace(/<\/?(b|i|code|a|mark)\b[^>]*>/g, '') // inline: no gap
  .replace(/<[^>]+>/g, ' ')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/&#39;/g, "'")
  .replace(/\s+/g, ' ');
const plain = (line) => line
  .replace(/^#+ |^- /, '')
  .replace(/\*\*|`/g, '')
  .replace(/(^|[^\w*])\*([^*]+)\*/g, '$1$2')
  .replace(/\s+/g, ' ')
  .trim();

test('served at /privacy with its own stylesheet, readable on a phone', async () => {
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
  assert.match(html, /<html lang="en">/);
  assert.match(html, /<link rel="stylesheet" href="\/privacy\/page\.css">/);
  await access(new URL('../../hosting/privacy/page.css', import.meta.url));
  const cfg = JSON.parse(await read('../../firebase.json'));
  assert.equal(cfg.hosting.public, 'hosting');
  assert.equal(cfg.hosting.cleanUrls, true);
});

test('works under the site\'s Content-Security-Policy', async () => {
  // No scripts at all, no inline styles or handlers, nothing loaded from
  // another site (links are fine: they're navigation, not loads).
  assert.doesNotMatch(html, /<script|<style|\sstyle=|\son[a-z]+=|<iframe|<img|<form/i);
  const cfg = JSON.parse(await read('../../firebase.json'));
  const csp = cfg.hosting.headers.flatMap((h) => h.source === '**' ? h.headers : [])
    .find((h) => h.key === 'Content-Security-Policy').value;
  assert.match(csp, /style-src 'self'/); // the stylesheet is on the same site
  const css = await read('../../hosting/privacy/page.css');
  assert.doesNotMatch(css, /@import|url\(/); // nothing fetched from elsewhere
});

test('says exactly what the policy says (every line of the policy is on the page)', () => {
  const lines = md.split('\n').filter((l) => l.trim() && !l.startsWith('>'));
  const missing = lines.map(plain).filter((l) => !pageText.includes(l));
  assert.deepEqual(missing, []);
  // And the draft note for the developer isn't shown to the public.
  assert.doesNotMatch(pageText, /Remove this note/);
});

test('has the support contact and a working link to account deletion', () => {
  assert.match(html, /<a href="mailto:doe68196@gmail\.com">doe68196@gmail\.com<\/a>/);
  assert.match(html, /<a href="\/delete-account">/);
  assert.match(html, /<a href="https:\/\/pennywise-b986a\.web\.app\/delete-account">/);
});

test('the key disclosures are there and match the app and the deletion page', async () => {
  for (const s of [
    'africa-south1', 'Johannesburg, South Africa', 'transfer',
    '1,500 new records per day', '3,000 changes per day',
    'Firebase App Check with Google Play Integrity', 'IP address',
    'Also import the last 30 days', 'off by default',
  ]) assert.ok(pageText.includes(s), s);
  const sentence =
    "If anything was added or changed in your account on the day you delete it, small usage counters containing only a number and timestamp may remain under your deleted account's ID. They contain no financial transaction details and cannot be accessed through PennyWise.";
  assert.ok(pageText.includes(sentence));
  const deletePage = (await read('../../hosting/delete-account/index.html')).replace(/&#39;/g, "'");
  assert.ok(deletePage.includes(sentence));
  const app = await read('../../lib/screens/delete_account_screen.dart');
  assert.match(app, /small usage counters containing only a number and '/);
});

test('the limits stated match the app', async () => {
  const limits = await read('../../lib/data/write_limit.dart');
  assert.match(limits, /static const daily = 1500;/);
  assert.match(limits, /static const edits = 3000;/);
  const rules = await read('../../firestore.rules');
  assert.match(rules, /function dailyWriteLimit\(\) \{\s*return 1500;/);
  assert.match(rules, /function dailyEditLimit\(\) \{\s*return 3000;/);
});

// Publication gate: stays "todo" (reported, not failing) until every
// [CONFIRM] is resolved and the working-draft label is removed.
test('ready to publish: no [CONFIRM] placeholders and no draft label', { todo: 'needs the developer\'s details' }, () => {
  assert.doesNotMatch(md, /\[CONFIRM/);
  assert.doesNotMatch(md, /WORKING DRAFT/);
  assert.doesNotMatch(html, /\[CONFIRM|WORKING DRAFT/);
});
