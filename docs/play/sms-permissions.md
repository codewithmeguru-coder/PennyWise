# SMS permissions: what PennyWise asks for and the Play declaration

> Prepared from the code at commit 868fece+ (31 Oct 2026). Before you submit,
> compare it with Google's current "SMS and Call Log permissions" policy in the
> Play Console Help Center, because the wording changes from time to time.

## Permissions in the manifest
| Permission | Why it's needed | When it's asked |
|---|---|---|
| `READ_SMS` | Reads transaction messages already in the inbox. This catches up on ones that arrived while the app was closed, and lets the optional "Import last 30 days" work. | Only after the user turns on **Automatic Transaction Detection** in Settings and taps **Continue** on PennyWise's explanation. |
| `RECEIVE_SMS` | Notices a new transaction message while the app is open, so it's added straight away. | Same request as above. |
| `INTERNET` | Firebase sign-in and data, plus exchange rates. | Not a runtime permission. |
| `USE_BIOMETRIC` | App Lock fingerprint or face unlock, through Android's own prompt. | When App Lock with biometrics is turned on. |

There are no Call Log, phone-number, contacts or location permissions. Telephony is marked as not required.

## What the code actually does with SMS
- **Who is read:** only messages from M-Pesa, Airtel Money and Equity Bank. The Android code checks each message's sender against that list and skips everything else on the phone, so other messages never reach the app's logic, storage or network.
- **What is stored in the user's Firebase account:** for each transaction message, the amount, type, merchant or sender, date, transaction code and which SIM received it. A copy of that one message is stored with every run of 6 or more digits masked (for example `07*****678`).
- **What isn't stored:** personal messages, OTPs, promotions, and failed or unreadable messages. For held or unreadable messages, only their transaction codes are kept on the phone, so nothing is added twice.
- **No background service:** messages are checked when the app opens, or while it's open.
- **Not the default SMS app:** PennyWise never sends SMS and never reads anything outside the allowlist.

## Disclosure shown before Android's permission request
Shown in Settings before Android's dialog. It was updated in this phase to name Equity Bank and the SIM:

> **Allow PennyWise to read transaction SMS?**
>
> To add your M-Pesa, Airtel Money and Equity Bank transactions automatically, PennyWise needs permission to read and receive SMS on this phone.
>
> - Only messages from M-Pesa, Airtel Money and Equity Bank are used. All other SMS are skipped on the phone and never leave it.
> - From each transaction message, only the amount, type, merchant/sender, date, transaction code and which SIM received it are saved to your account, plus a copy of that one message with phone and account numbers masked.
> - You can turn this off at any time in Settings.
>
> [Not now] [Continue]

## Draft text for the Permissions Declaration Form
**Core functionality:** PennyWise is a personal budgeting and expense tracker for Kenya. Its core feature is turning the user's own mobile-money and bank transaction SMS (M-Pesa, Airtel Money, Equity Bank) into a ledger of income, spending, transfers and savings. The app uses that ledger for monthly budgets, category spending, account balances and Fuliza (overdraft) fee reports. Most transactions for these users arrive only as SMS; no bank or mobile-money API is available to individuals.

**Permitted use case:** SMS-based money management. This means tracking and categorising the user's own financial transactions from SMS, and budgeting.

**Why READ_SMS and RECEIVE_SMS:** RECEIVE_SMS adds a new transaction the moment its SMS arrives. READ_SMS catches up on transaction SMS that arrived while the app was closed, and on recent history if the user asks. Without them, users would have to type every transaction by hand.

**User control:** off by default. The user turns it on, sees PennyWise's explanation, then Android's dialog. They can turn it off in Settings at any time. Only allowlisted senders are processed.

**Data handling:** messages from other senders are ignored on the device. Transaction details, and a masked copy of each transaction message, are stored in the user's own Firebase account and are not shared with third parties.

**Demo video (record on a test account):**
1. Settings › Automatic Transaction Detection.
2. PennyWise's explanation, then Continue, then Android's permission dialog.
3. A transaction SMS arriving, and the "transaction detected" notice.
4. The transaction in the list and on Home.
5. Turning detection off.

## Approval risks
1. **Policy fit:** Google limits these permissions to specific uses. "SMS-based money management" has been one of the allowed exceptions, but check that it's still listed and that your description matches it word for word.
2. **Equity Bank messages:** these widen what is read. That's fine if they're described as the user's own bank transaction SMS, as above.
3. **Video and disclosure must match the app:** keep the disclosure text exactly as it appears in the build you upload.
4. **Rejection fallback:** if Google rejects the declaration, the app can ship without SMS permissions, with manual entry only. That would remove the app's main feature, so it's worth discussing before it's needed.
5. **Account deletion:** Play also requires a way to delete the account (see `release-checklist.md`). That's a separate blocker, but reviewers check it.
