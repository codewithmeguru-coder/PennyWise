# Account deletion: how it works and how to deploy it

## In the app: Settings › Delete account (at the bottom)
1. The screen says deletion is permanent and lists what goes.
2. The user ticks **I understand this can't be undone** and types **DELETE**.
3. They confirm it's them, just before deleting:
   - password accounts enter their password;
   - Google accounts pick the **same** Google account again. A different account is refused.
4. A last dialog asks **Delete everything now?** The user picks **Keep my account** or **Delete**.
5. PennyWise then deletes, in this order:
   1. It records a deletion request at `users/{uid}/deletionRequest/current`.
   2. It deletes these collections in batches of 200: `transactions`, `categoryRules`, `budgets`, `categoryBudgets`, `balanceAnchors`, `accounts`, `categories`.
   3. It deletes `private/avatar` (the profile photo; Firebase Storage isn't used).
   4. It removes the deletion request.
   5. It deletes the `users/{uid}` profile.
   6. It clears this phone's PennyWise settings for that user, and App Lock.
   7. It deletes the Firebase sign-in itself.
6. The app returns to the sign-in screen and says the account was deleted.

**If it stops halfway** (no connection, app closed): the deletion request stays. Opening Delete account again shows "A deletion you started didn't finish" and **Finish deleting**, which continues where it stopped, because deleting what's already gone does nothing. If only the sign-in deletion fails, the data is already gone; confirming again and retrying removes the sign-in.

**Ownership:** everything runs as the signed-in user. The Firestore rules only allow access to `users/{their uid}`, and the records that are normally kept forever (accounts, balance history, categories) can be deleted only by their owner, and only while that owner's deletion request exists. Another user can't create someone else's request or delete their records; the rules tests check this.

## Public page: `hosting/delete-account/`
- The person signs in on the page (Google, or email and password). That sign-in is the proof of ownership. An email address alone never deletes anything.
- They tick **I understand**, type **DELETE**, and confirm.
- The page runs the same deletion as the app, then shows **Done**, which confirms the request was received and completed.
- It also explains what is deleted and what isn't kept. Fill in the `[CONFIRM contact email]` in `index.html` first.

**URL for Google Play:** `https://pennywise-b986a.web.app/delete-account`

## What needs your approval (production changes)
1. **Deploy the Firestore rules.** This is needed before account deletion can work in the app or on the page.
   ```
   firebase deploy --only firestore:rules --project pennywise-b986a
   ```
   I'll back up the live rules first and confirm afterwards that they match the tested file.
2. **Deploy the page** (Firebase Hosting, free on the Spark plan):
   ```
   firebase deploy --only hosting --project pennywise-b986a
   ```
   `pennywise-b986a.web.app` is already an authorized domain for Firebase sign-in, so Google sign-in works on the page.
3. **Install the app build** that has Settings › Delete account.

Test with a throwaway test account, never your main one: register it, add a few transactions and an account, delete it from the app, and check in the Firebase console that `users/{its uid}` is gone.

## Google Play requirements (as of Oct 2026; re-check in Play Console)
- In-app way to start deletion: **done**.
- Web link where users can request deletion without reinstalling: **done** (needs deploying).
- Data deleted or kept is explained: on the page and in the privacy policy draft.
- Data safety form: answer **Yes, users can request deletion** once both are live.
- Still open: fill in the contact email, and publish the privacy policy with section 7 updated.
