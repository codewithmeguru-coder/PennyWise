// The account deletion page's behaviour (served as a file, so the page's
// Content-Security-Policy can forbid inline scripts).
import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js';
import { getAuth, GoogleAuthProvider, signInWithPopup, signInWithEmailAndPassword, onAuthStateChanged, signOut, deleteUser } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js';
import { getFirestore, collection, doc, getDoc, getDocs, query, limit, writeBatch, setDoc, updateDoc, deleteDoc, serverTimestamp } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js';
// Absolute: the page is served at /delete-account (no trailing slash).
import { canDelete, deleteEverything } from '/delete-account/deletion.mjs';

const app = initializeApp({"apiKey": "AIzaSyBUkPTv_nRPfFKTqq82g_tVqO6fDTWS5KU", "appId": "1:240925304261:web:5265f292d706c9d80997ac", "messagingSenderId": "240925304261", "projectId": "pennywise-b986a", "authDomain": "pennywise-b986a.firebaseapp.com"});
const auth = getAuth(app);
const db = getFirestore(app);
const $ = (id) => document.getElementById(id);
const say = (t) => { $('status').textContent = t; };

function refresh() {
  $('delete').disabled = !canDelete({ signedIn: !!auth.currentUser, understood: $('understood').checked, typed: $('word').value });
}
['understood', 'word'].forEach((id) => $(id).addEventListener('input', refresh));

onAuthStateChanged(auth, (user) => {
  $('signin').classList.toggle('hidden', !!user);
  $('confirm').classList.toggle('hidden', !user);
  $('who').textContent = user ? (user.email || 'your account') : '';
  refresh();
});

$('google').onclick = async () => {
  try { say(''); await signInWithPopup(auth, new GoogleAuthProvider()); }
  catch (e) { say('Google sign-in failed. Please try again.'); }
};
$('emailSignIn').onclick = async () => {
  try { say(''); await signInWithEmailAndPassword(auth, $('email').value.trim(), $('password').value); }
  catch (e) { say('Incorrect email or password.'); }
};
$('signout').onclick = () => signOut(auth);

$('delete').onclick = async () => {
  const user = auth.currentUser;
  if (!user || !confirm('Delete your PennyWise account and all its data now? This can\'t be undone.')) return;
  $('delete').disabled = true;
  const home = doc(db, 'users', user.uid);
  const marker = doc(db, 'users', user.uid, 'deletionRequest', 'current');
  try {
    await deleteEverything({
      markDeletion: () => setDoc(marker, { requestedAt: serverTimestamp() }),
      deleteSome: async (c) => {
        const snap = await getDocs(query(collection(home, c), limit(200)));
        if (snap.empty) return 0;
        const batch = writeBatch(db);
        snap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
        return snap.size;
      },
      deleteDoc: (path) => deleteDoc(doc(home, ...path.split('/'))),
      clearWriteCounter: async () => {
        // The daily write and edit counters.
        for (const name of ['daily', 'edits']) {
          const counter = doc(home, 'limits', name);
          if (!(await getDoc(counter)).exists()) continue;
          try {
            await deleteDoc(counter);
          } catch (e) {
            if (!e || e.code !== 'permission-denied') throw e;
            // Today's counter stays so the daily limit can't be reset; only
            // the last record's path is removed.
            await updateDoc(counter, { lastPath: '' });
          }
        }
      },
      clearMarker: () => deleteDoc(marker),
      deleteProfile: () => deleteDoc(home),
      deleteSignIn: () => deleteUser(user),
    }, (step) => say(step + '…'));
    $('confirm').classList.add('hidden');
    $('signin').classList.add('hidden');
    $('done').classList.remove('hidden');
    say('');
  } catch (e) {
    const recent = e && e.code === 'auth/requires-recent-login';
    say(recent
      ? 'Your data is deleted. Sign out, sign in again and press Delete once more to remove the sign-in too.'
      : 'Deletion stopped (' + (e && e.code ? e.code : 'error') + '). Nothing is lost by trying again; it continues where it stopped.');
    refresh();
  }
};
