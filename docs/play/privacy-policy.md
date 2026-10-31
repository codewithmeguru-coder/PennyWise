# PennyWise Privacy Policy (DRAFT, for your review)

> Items marked **[CONFIRM]** need your decision before you publish. This draft
> describes what the app's code does as of 31 Oct 2026. Publish it at a public
> URL (for example Google Sites or a public GitHub Pages site) and put that
> URL in Play Console and inside the app.

**Effective date:** [CONFIRM date]
**Developer:** [CONFIRM name or business name], Kenya
**Contact:** doe68196@gmail.com

PennyWise is a personal expense tracker. This policy explains what information the app uses, where it's kept, and the choices you have.

## 1. Information you give us
- **Account:** your email address and password (when you register with email), or your Google account's name, email address and profile photo link (when you choose *Continue with Google*). Sign-in is handled by Google Firebase Authentication. PennyWise never sees your password.
- **Profile photo (optional):** if you add one, a resized copy is stored in your PennyWise account.
- **What you enter:** transactions, categories, budgets, accounts and their starting balances, and notes.

## 2. Transaction SMS (only if you turn it on)
Automatic Transaction Detection is **off by default**. If you turn it on, PennyWise first explains what it reads, then Android asks for SMS permission.
- PennyWise only uses messages from **M-Pesa, Airtel Money and Equity Bank**. Every other SMS is skipped on your phone and never leaves it.
- From each transaction message it saves the amount, type, merchant or sender, date, transaction code and which SIM received it. It also saves a copy of that one message with phone and account numbers masked.
- Messages are checked on your phone when the app is open. There's no background service, and PennyWise never sends SMS.
- You can turn detection off at any time in Settings.

## 3. Information kept only on your phone
- App settings: appearance, hidden savings amounts, detection settings, and the transaction codes of messages already handled or held back.
- App Lock: your PIN is stored as a one-way hash in Android's secure storage. Fingerprint and face unlock are handled by Android; PennyWise never receives biometric data.
- Safety copies made by the one-off repair tools, so you can undo them.
- Device backup of this app's data is turned off.

## 4. Where your data is stored
Your account data (sections 1–2) is stored in **Google Firebase** (Cloud Firestore and Firebase Authentication), under your own account. Firestore security rules allow only your signed-in account to read or write it. Data travels over encrypted connections (HTTPS/TLS), and Google encrypts it at rest. [CONFIRM: Firebase project region, shown in the Firebase console.]

## 5. Other services
- **Google (Firebase, Google Sign-In):** used to provide sign-in and storage.
- **Exchange rates:** for card payments in another currency (such as USD), PennyWise downloads that day's public exchange rate from a free currency-rate service (served through jsDelivr and Cloudflare). The request contains only the date and currency. As with any web request, those services can see your device's IP address.
- No advertising, no analytics and no crash-reporting SDKs are included. PennyWise does not sell your data or share it with third parties for their own use.

## 6. How we use information
Only to provide the app: recording and categorising your transactions, budgets, balances, reports, and sign-in. No profiling, ads or credit scoring.

## 7. Retention and deletion
Your data stays in your account until you delete it. You can delete your account and all its data at any time:
- **In the app:** Settings › Delete account.
- **On the web:** https://pennywise-b986a.web.app/delete-account. Sign in to prove the account is yours; an email address alone isn't enough.

Deletion removes your sign-in, transactions (including the masked SMS copies), accounts and balance history, budgets, categories, learned categories, profile and profile photo, straight away. PennyWise keeps no other copies and nothing is kept for legal reasons. Google may keep encrypted system backups and logs for a limited time under its own policies.

## 8. Your choices
- Turn SMS detection off, or remove the permission in Android settings.
- Edit or delete individual transactions in the app.
- Remove your profile photo in Settings.
- Ask about your data at doe68196@gmail.com. To delete your account, use the app or the web page above; signing in there proves the account is yours, so email alone can't delete an account.

## 9. Children
PennyWise is meant for adults managing their own money and isn't directed at children under 18. [CONFIRM target age.]

## 10. Accuracy
Amounts converted from other currencies are estimates at the market rate on the day; your bank's rate and fees may differ. Reports and balances depend on the messages and entries available. PennyWise is a record-keeping tool, not financial advice.

## 11. Changes
We'll update this page and the effective date when practices change. Significant changes will also be shown in the app.

## 12. Kenyan data protection
PennyWise handles personal data in line with Kenya's Data Protection Act, 2019. [CONFIRM: whether you need to register with the Office of the Data Protection Commissioner; check its current thresholds.]
