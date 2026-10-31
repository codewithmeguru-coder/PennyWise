# Google Play Data safety: preparation

> Based on the code at 31 Oct 2026. Answers marked **[CONFIRM]** need your
> decision. Google treats Firebase as a service provider acting for you, so
> data sent to it counts as **collected**, not **shared**.

## Overview answers
| Question | Answer |
|---|---|
| Does the app collect or share any required user data types? | Yes (collects; does not share) |
| Is all collected data encrypted in transit? | Yes (Firebase and HTTPS) |
| Can users request that their data be deleted? | **Not yet.** In-app account deletion and a web request link must be added first (blocker). |
| Shared with third parties? | No |

## Data types
| Data type (Play's category) | Collected? | Optional? | Purpose | Notes |
|---|---|---|---|---|
| Personal info › Name | Yes | Yes (Google name, or the name you register with) | Account management, app functionality | Shown in the greeting |
| Personal info › Email address | Yes | No | Account management | Firebase Authentication |
| Financial info › Other financial info | Yes | No (it's the app's purpose) | App functionality | Transactions, balances, budgets, accounts |
| Financial info › Purchase history | Yes | No | App functionality | Payments read from SMS, including merchant names |
| Messages › SMS or MMS | Yes | Yes (detection is off by default) | App functionality | A masked copy of each transaction SMS from M-Pesa, Airtel Money or Equity only |
| Photos and videos › Photos | Yes | Yes | App functionality (profile photo) | Stored in your account |
| App activity, Device IDs, Location, Contacts, Audio, Health | No | | | No analytics, ads or crash SDKs |

**[CONFIRM]:** Firebase Authentication itself handles technical data such as IP address and device information to sign users in. Check Google's current Data safety guidance for Firebase, and declare whatever it lists for Authentication and Firestore.

## Processed only on the phone (not collected)
- The full SMS inbox scan. Messages from other senders are skipped on the device.
- App Lock PIN hash (secure storage) and biometric checks (Android).
- Settings, handled message codes, and repair-tool safety copies.

## Sent to a third party, without user data
- Exchange-rate requests contain only a date and a currency code. Declare "no user data shared" for these.

## Security section
- Data is encrypted in transit: yes.
- Users can request deletion: only after the deletion feature is added.
- Independent security review: no.
