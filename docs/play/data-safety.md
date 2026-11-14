# Google Play Data safety: preparation

> Based on the code at 1 Nov 2026 and Google's own documentation (sources at
> the end). Answers marked **[CONFIRM]** need your decision; Google says the
> developer alone is responsible for the answers. Google treats Firebase as
> a service provider acting for you, so data sent to it counts as
> **collected**, not **shared**.

## Overview answers
| Question | Answer |
|---|---|
| Does the app collect or share any required user data types? | Yes (collects; does not share) |
| Is all collected data encrypted in transit? | Yes (Firebase and HTTPS) |
| Can users request that their data be deleted? | Yes: in the app (Settings › Delete account) and at https://pennywise-b986a.web.app/delete-account |
| Shared with third parties? | No |

## Data types
| Data type (Play's category) | Collected? | Optional? | Purpose | Notes |
|---|---|---|---|---|
| Personal info › Name | Yes | Yes (Google name, or the name you register with) | Account management, app functionality | Shown in the greeting |
| Personal info › Email address | Yes | No | Account management | Firebase Authentication |
| Financial info › Other financial info | Yes | No (it's the app's purpose) | App functionality | Transactions, balances, budgets, accounts |
| Financial info › Purchase history | Yes | No | App functionality | Payments read from SMS, including merchant names |
| Messages › SMS or MMS | Yes | Yes (detection is off by default) | App functionality | A masked copy of each transaction SMS from M-Pesa, Airtel Money or Equity Bank only. Includes earlier messages from those senders when the user starts an import (see below) |
| Photos and videos › Photos | Yes | Yes | App functionality (profile photo) | Stored in your account |
| Device or other IDs | **[CONFIRM]**, likely Yes | No | Fraud prevention, security and compliance | Play Integrity / App Check and Firebase technical data; see below |
| App activity › Other actions | **[CONFIRM]**, likely No | No | Fraud prevention, security and compliance | The two daily usage counters: a count, a time and the ID of the last record added or changed. They describe the user's own records, already declared above. Decide whether to declare them separately |
| Location, Contacts, Audio, Health, Web browsing | No | | | |
| App info and performance (crash logs, diagnostics) | No | | | No analytics, ads or crash SDKs |

## Technical data handled by Google's SDKs: [CONFIRM] how to declare
Google's Firebase data-disclosure page lists what each SDK the app uses collects automatically:
- **Firebase Authentication:** IP address ("to provide added security and prevent abuse during sign-up and authentication"), user agent strings, the Firebase Android App ID, and the Firebase user agent.
- **Cloud Firestore:** the Firebase user agent only.
- **Firebase user agent** (sent by the SDKs above): device metadata (OS version, name, model, brand and form factor), the installing app store, and the Firebase SDKs and versions used. Google says it is never linked to a user or device identifier.
- **App Check with the Play Integrity provider:** a Play Integrity token. The Play Integrity data-safety section lists what it involves:
  - always: app-provided request fields, app metadata (package name, version, signing certificate), Google Play licence status, and device information (a key attestation certificate and a device attestation token);
  - only if the app opts in to "environment details", which PennyWise doesn't: app activity and Play Protect status.
  - Purpose: verify app and device integrity and licensing. It's encrypted, not transferred to third parties, and deleted after a fixed retention period.

Google provides this information "to help you complete" the form, but you decide the answers. The likely choices to confirm:
- **Device or other IDs: Yes, for Fraud prevention, security and compliance.** This covers the attestation token and certificate from Play Integrity and the IP address used by Firebase Authentication.
- **Optional: No.** The integrity check and sign-in always run.
- **Shared: No.** Google processes this as your service provider.

## Processed only on the phone (not collected)
- Reading SMS from other senders. Messages from other senders are skipped on the device.
- Inbox reads: when the app opens (messages since the last check), and when the user asks for earlier messages ("Also import the last 30 days", Fuliza history, repair tools). Only the transaction messages from the three senders are saved, as declared above.
- App Lock PIN hash (secure storage) and biometric checks (Android).
- Settings, handled message codes, and repair-tool safety copies.

## Sent to a third party, without user data
- Exchange-rate requests contain only a date and a currency code. Declare "no user data shared" for these.

## Where data is stored (not a form question, but needed for the policy)
- Cloud Firestore: **africa-south1** (Johannesburg, South Africa), read from the project's database settings on 1 Nov 2026.
- Firebase Authentication: a global Google service.
- For Kenyan users this is a transfer of personal data outside Kenya. See `pennywise-privacy-policy-prep.md` (project Library) for what still needs your decision.

## Security section
- Data is encrypted in transit: yes.
- Users can request deletion: yes (in the app and on the web page).
- Independent security review: no.

## Sources
- Firebase, "Prepare for Google Play's data disclosure requirements": https://firebase.google.com/docs/android/play-data-disclosure
- Firebase, "Privacy and Security in Firebase": https://firebase.google.com/support/privacy
- Android Developers, "Play Integrity API: terms and data safety": https://developer.android.com/google/play/integrity/terms#data-safety
