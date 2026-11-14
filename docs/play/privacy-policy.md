# PennyWise Privacy Policy (UNPUBLISHED WORKING DRAFT)

> **Not published.** Items marked **[CONFIRM]** need the developer's
> decision. Remove this note and the "UNPUBLISHED WORKING DRAFT" label only
> when every [CONFIRM] is resolved. This draft describes what the app's code
> does as of 1 Nov 2026. The intended public address is
> https://pennywise-b986a.web.app/privacy (`hosting/privacy/index.html`
> must say the same thing).

**Effective date:** [CONFIRM: the date you publish this policy]
**Developer:** [CONFIRM: your legal or publishing name, as shown on Google Play], Kenya
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
- **When messages are read:** while the app is open, as each new message arrives; and when you open the app, the messages from these senders that arrived since it last checked, so none are missed while it was closed. There's no background service, and PennyWise never sends SMS.
- **Earlier messages:** only when you ask, PennyWise also reads earlier messages from these senders that are already on your phone: for example when you choose *Also import the last 30 days*, import your Fuliza history, or run one of the one-off repair tools in Settings. The same rules apply: other senders are skipped and only transaction details are saved.
- You can turn detection off at any time in Settings.

## 3. Information kept only on your phone
- App settings: appearance, hidden savings amounts, detection settings, and the transaction codes of messages already handled or held back.
- App Lock: your PIN is stored as a one-way hash in Android's secure storage. Fingerprint and face unlock are handled by Android; PennyWise never receives biometric data.
- Safety copies made by the one-off repair tools, so you can undo them.
- Device backup of this app's data is turned off.

## 4. Where your data is stored
Your account data (sections 1–2 and the usage counters in section 5) is stored in **Google Firebase** (Cloud Firestore and Firebase Authentication), under your own account. Firestore security rules allow only your signed-in account to read or write it. Data travels over encrypted connections (HTTPS/TLS), and Google encrypts it at rest.

**Location and transfer outside Kenya:** PennyWise's Cloud Firestore database is located in Google Cloud's **africa-south1** region (Johannesburg, South Africa). Using PennyWise therefore means your account data is transferred to, and stored in, South Africa, and is processed by Google as PennyWise's service provider. Firebase Authentication is a global Google service, so your sign-in details may also be processed in other countries where Google operates. [CONFIRM: the legal basis you rely on for this transfer under sections 48–50 of Kenya's Data Protection Act, 2019. See the notes in `pennywise-privacy-policy-prep.md`; do not publish a basis or safeguard you haven't confirmed.]

## 5. Daily usage limits
To protect the service from misuse, each account has two small usage counters, stored with your account:
- **New records:** how many records (transactions, learned categories, categories, accounts and starting-balance history) were added today. The limit is **1,500 new records per day**.
- **Changes:** how many times existing information was changed today (for example editing a transaction, an account, a budget, a category limit, your profile or photo). The limit is **3,000 changes per day**.

Each counter holds only a number, the time it was last used and the ID of the last record added or changed (for example `transactions/<record ID>`). It contains no amounts, names or message text. A day is a UTC day (00:00 to 23:59 UTC, which is 03:00 to 02:59 in Kenya); each counter starts again from 1 on a new day. Only your signed-in account can read your counters, and they are used only to enforce these limits. When a limit is reached, the app tells you, and further additions or changes wait until the next day.

## 6. Other services
- **Google Firebase and Google Sign-In:** provide sign-in and storage.
- **Firebase App Check with Google Play Integrity:** checks that requests to PennyWise's database and sign-in come from the genuine PennyWise app on a genuine Android device, to block misuse by modified apps or scripts. To do this, Google Play services sends Google an integrity token. According to Google, this involves app information (the app's package name, version number and signing certificate, and its Google Play licence status) and device information (a key attestation certificate and a device attestation token generated by Google Play services). Google uses this only to verify app and device integrity, encrypts it, doesn't share it with third parties and deletes it after a fixed period.
- **Technical information processed by Google:** when the app talks to Firebase, Google processes technical information needed to provide and protect the service. According to Google's documentation, this includes your **IP address** and **user agent** (used by Firebase Authentication for security and to prevent abuse at sign-up and sign-in), and device information sent by the Firebase libraries: the Android version and the device's name, model, brand and form factor, which app store installed the app, and which Firebase libraries and versions the app uses. Google encrypts this in transit and doesn't transfer it to third parties except the sub-processors it uses to provide Firebase. PennyWise itself doesn't collect or store your IP address or device information.
- **Exchange rates:** for card payments in another currency (such as USD), PennyWise downloads that day's public exchange rate from a free currency-rate service (served through jsDelivr and Cloudflare). The request contains only the date and currency. As with any web request, those services can see your device's IP address.
- No advertising, no analytics and no crash-reporting SDKs are included. PennyWise does not sell your data or share it with third parties for their own use.

## 7. How we use information
Only to provide the app: recording and categorising your transactions, budgets, balances, reports, and sign-in; and to keep the service secure (the integrity checks and daily limits above). No profiling, ads or credit scoring.

## 8. Retention and deletion
Your data stays in your account until you delete it. You can delete your account and all its data at any time:
- **In the app:** Settings › Delete account.
- **On the web:** https://pennywise-b986a.web.app/delete-account. Sign in to prove the account is yours; an email address alone isn't enough.

Deletion removes your sign-in, transactions (including the masked SMS copies), accounts and balance history, budgets, categories, learned categories, profile and profile photo, straight away. Apart from the usage counters described next, PennyWise keeps no other copies and nothing is kept for legal reasons. If anything was added or changed in your account on the day you delete it, small usage counters containing only a number and timestamp may remain under your deleted account's ID. They contain no financial transaction details and cannot be accessed through PennyWise. Google may keep encrypted system backups and logs for a limited time under its own policies.

## 9. Your choices
- Turn SMS detection off, or remove the permission in Android settings.
- Edit or delete individual transactions in the app.
- Remove your profile photo in Settings.
- Ask about your data at doe68196@gmail.com. To delete your account, use the app or the web page above; signing in there proves the account is yours, so email alone can't delete an account.

## 10. Children
PennyWise is meant for adults managing their own money and isn't directed at children under [CONFIRM: minimum age, for example 18].

## 11. Accuracy
Amounts converted from other currencies are estimates at the market rate on the day; your bank's rate and fees may differ. Reports and balances depend on the messages and entries available. PennyWise is a record-keeping tool, not financial advice.

## 12. Changes
When our practices change, we'll update this page and the effective date at the top. Please check this page from time to time.

## 13. Kenyan data protection
PennyWise handles personal data in line with Kenya's Data Protection Act, 2019. [CONFIRM: your registration status with the Office of the Data Protection Commissioner (ODPC). Either give your registration number, or remove this placeholder once you've confirmed registration isn't required. See `pennywise-privacy-policy-prep.md`.]
