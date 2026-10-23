# PennyWise Stage 3: phone test checklist

**Build under test**

| | |
|---|---|
| Phone | Redmi Note 14 Pro (model 24116RACCG), Android 16, device ID `4995scrcwktsknww` |
| APK | `build\app\outputs\flutter-apk\app-debug.apk`, 226,955,969 bytes |
| APK SHA-256 | `ade01d7b84e43bc52724af780353c0244b68b9dd7474d972edd9418782193565` |
| Package | `com.example.pennywise`, version 1.0.0 (1), debug-signed |
| Firestore rules | ruleset `778ac359`, SHA-256 `20e7d11b656e2aac19136f59a3f0d07f65eb8bffaba419367e3c411848c7590a` |
| Code | branch `phase-3-categorization` at `4ef3ff5` plus uncommitted Stage 3 changes |
| Automated checks | `flutter analyze` clean · 245 Flutter tests pass · 133 rules tests pass |

## How to use this checklist

1. Work through the groups in order (A → E).
2. For each test, follow **Steps**, compare with **Expected**, then write what you saw in **Actual**.
3. Tick exactly one status box: `[x] Pass`, and so on. Leave the rest as `[ ]`.
4. If something goes wrong, take a screenshot and note its file name under **Notes / evidence**.
5. Fill in the summary table in section F at the end.

A test is only marked Pass after you have done it on the phone, or where the **Notes** cite automated evidence that covers it. Nothing below is pre-marked Pass.

## Keep your real money records safe

Some tests **save new data**. They are marked **[TEST ACCOUNT]**. Run them **only while signed in to a separate test login**, never your real Google account.

**One-time setup for a test login**

1. Open PennyWise. Go to **Settings → Sign out**.
2. On the sign-in screen, choose **Create account** (email and password). Use an email address you control that is **not** your main one, for example a second address.
3. Do **not** turn on SMS detection in the test login. Leave it off for the whole session.
4. When you finish testing, sign out and sign back in with Google to return to your real data.

If you can't or don't want to create a test login, mark every **[TEST ACCOUNT]** test as **Blocked**, with the note "no test login". **Don't run them on your real account.**

**Important notes about your real account**

- **"Set up accounts"** on the Home screen creates 7 new account records: SIM 1 and SIM 2 M-Pesa, Ziidi and Fuliza for each SIM, and Cash. It doesn't change any transaction. The rules don't allow these records to be deleted; they can only be hidden. **Try it in the test login first.** Do it on your real account only when you're happy with how it looks.
- Never delete, rewrite or bulk-edit existing transactions during testing.
- Don't run any tool that changes old records during this test. This build has no history-fix screen; it's a later stage that needs your approval.

---

## A. Installation and startup

### A1 · Correct phone connected
- **Steps:** Done by Claude before installing: `flutter devices` and `adb getprop`.
- **Expected:** Only one Android phone is listed: Redmi Note 14 Pro, ID `4995scrcwktsknww`.
- **Actual:** Redmi Note 14 Pro (24116RACCG), Android 16, ID `4995scrcwktsknww`. It was the only phone listed.
- **Status:** [ ] Not tested  [x] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Automated pre-install check, 23 Oct 2026.

### A2 · APK exists and its fingerprint is recorded
- **Steps:** Done by Claude: file size and SHA-256 of the APK.
- **Expected:** The file exists, and the SHA-256 matches the table at the top.
- **Actual:** 226,955,969 bytes; SHA-256 `ade01d7b…93565`.
- **Status:** [ ] Not tested  [x] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Automated pre-install check.

### A3 · Installed over the existing app (no uninstall)
- **Steps:** Done by Claude: `adb install -r` (update in place) with the same package name and the same signing certificate as the installed app.
- **Expected:** Android reports `Success`. Nothing is uninstalled and no app data is cleared.
- **Actual:** `adb install -r` → `Success` on 23 Oct 2026 12:55 (phone time). First install date unchanged (20 Oct 2026), so the app was updated, not reinstalled. The installed APK's SHA-256 matches `ade01d7b…93565`.
- **Status:** [ ] Not tested  [x] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Automated install check. Same signing certificate (Android Debug, SHA-256 `333d14e1…5753c`) as the previous install.

### A4 · App starts without errors
- **Steps:** Tap the PennyWise icon on the home screen. Wait up to 10 seconds.
- **Expected:** The App Lock screen appears, if App Lock is on, and then the Home screen. There's no crash, no "PennyWise keeps stopping" message and no red error screen.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### A5 · You're still signed in and your data is intact
- **Steps:** After unlocking, look at Home. Open **Transactions**.
- **Expected:**
  - You are still signed in with Google; you aren't asked to sign in again.
  - Your transactions and totals look the same as before the update.
  - The newest transactions are still at the top.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** If you noted your **Available balance** before updating, write both numbers here.

---

## B. Accounts and dashboard

### B1 · Account setup card (real account, read only)
- **Steps:** On your **real** account, open Home and look at the top. **Don't tap** "Set up accounts" yet.
- **Expected:** A card titled **Set up your accounts** appears above the **Available balance** summary, with a **Set up accounts** button.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B2 · Create the starter accounts [TEST ACCOUNT]
- **Steps:** In the test login, tap **Set up accounts** on Home.
- **Expected:** Cards appear for SIM 1 M-Pesa, SIM 2 M-Pesa, Ziidi (SIM 1), Ziidi (SIM 2), Fuliza (SIM 1), Fuliza (SIM 2) and Cash, followed by an **Accounts** card.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B3 · SIM 1 and SIM 2 M-Pesa are separate [TEST ACCOUNT]
- **Steps:** Look at the account cards.
- **Expected:** "SIM 1 M-Pesa" and "SIM 2 M-Pesa" are two separate cards with separate balances.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B4 · Each SIM has its own Ziidi and Fuliza [TEST ACCOUNT]
- **Steps:** Tap the **Accounts** card to open the Accounts list. Read each account's line.
- **Expected:** There are four accounts: Ziidi (SIM 1), Ziidi (SIM 2), Fuliza (SIM 1) and Fuliza (SIM 2). Each one is linked to its own SIM's M-Pesa, never to the other SIM.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B5 · Cash account appears [TEST ACCOUNT]
- **Steps:** Look at the cards and the Accounts list.
- **Expected:** A **Cash** account is shown. No bank account is created automatically; banks are added only by you.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B6 · Account cards sit above the overall summary
- **Steps:** On Home, scroll to the top.
- **Expected:** The row of account cards (or the setup card) is **above** the "Available balance" summary card.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Also covered by automated widget test "account cards sit above the overall summary".

### B7 · Rename an account [TEST ACCOUNT]
- **Steps:** Accounts → tap **SIM 2 M-Pesa** → change **Name** to "Line 2" → **Save**.
- **Expected:** The list and the Home card both show "Line 2". No error appears.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B8 · Hide and show an account [TEST ACCOUNT]
- **Steps:**
  1. Accounts → tap **Line 2** → turn **Show this account** off → **Save**.
  2. Check Home.
  3. Turn **Show this account** back on and save.
- **Expected:**
  - After hiding, the card disappears from Home but the account stays in the Accounts list, marked hidden.
  - After showing it again, the card returns.
  - There is no Delete option.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### B9 · Starting balance vs estimated balance [TEST ACCOUNT]
- **Steps:**
  1. Look at the **Cash** card before setting anything.
  2. Accounts → tap **Cash** → **Starting balance (optional)** = 5000 → pick **Starting balance date** = today → **Save**.
- **Expected:**
  - Before: the Cash card shows a `~` before the amount and "Estimated · no starting balance".
  - After: it shows KSh 5,000.00 with no `~`, labelled "Calculated".
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** The card label is "From latest SMS" when an M-Pesa SMS states a balance.

### B10 · Unknown SIM is not guessed
- **Steps:** On your **real** account, look at Home.
- **Expected:** Older M-Pesa transactions, saved before SIM detection, are **not** assigned to SIM 1 or SIM 2. When accounts exist, they're counted on a card named **"M-Pesa, SIM not recorded"**.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** This card only appears once accounts are set up. Until then, mark it **Blocked** with the note "accounts not set up on real account". Also covered by automated test "unknown SIM: no account guessed".

---

## C. Transactions and transfers

### C1 · Existing transactions unchanged (real account, read only)
- **Steps:**
  1. Open **Transactions**.
  2. Scroll through the last two weeks.
  3. Open 2–3 older entries, then back out **without saving**.
- **Expected:**
  - Amounts, dates, categories and descriptions look as before.
  - No entries are duplicated or missing.
  - Older entries show no account id.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Press the back arrow. Don't tap **Save changes** on real entries.

### C2 · Account picker on a new transaction [TEST ACCOUNT]
- **Steps:** Tap **Add** → **Expense**. Look at the account field.
- **Expected:** The field is labelled "Paid from" and lists your own accounts (SIM 1 M-Pesa, SIM 2 M-Pesa, Cash). It doesn't list the generic M-Pesa/Cash options. Back out without saving.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C3 · Save an expense with an account [TEST ACCOUNT]
- **Steps:** **Add** → **Expense** → Amount 300 → Description "Test lunch" → **Paid from**: SIM 2 M-Pesa → Category **Food** → **Save transaction**.
- **Expected:** It saves with no error. The SIM 2 M-Pesa card drops by 300, and Spending this month rises by 300.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C4 · Save income with an account [TEST ACCOUNT]
- **Steps:** **Add** → **Income** → Amount 2000 → "Test income" → **Received into**: SIM 1 M-Pesa → Category **Salary** → Save.
- **Expected:** It saves. The SIM 1 M-Pesa card rises by 2,000, and Income this month rises by 2,000.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C5 · Transfer SIM 1 → SIM 2 [TEST ACCOUNT]
- **Steps:** **Add** → **Transfer** → Amount 500 → "To my other line" → **From account**: SIM 1 M-Pesa → **To account**: SIM 2 M-Pesa → Save.
- **Expected:**
  - It saves without error.
  - SIM 1 drops by 500 and SIM 2 rises by 500.
  - Spending and Income don't change.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Also covered by automated test "a transfer from SIM 1 to SIM 2 is saved with both account ids", and by rules test "SIM 1 -> SIM 2 transfer by account ids".

### C6 · Same account on both sides is refused [TEST ACCOUNT]
- **Steps:** **Add** → **Transfer** → From **SIM 1 M-Pesa** → To **SIM 1 M-Pesa** → Save.
- **Expected:** The form shows "Pick a different account", and nothing is saved.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C7 · Cash withdrawal: KSh 1,000 with a KSh 29 fee [TEST ACCOUNT]
- **Steps:**
  1. Write down the current SIM 1 M-Pesa card, Cash card and Spending this month.
  2. **Add** → **Expense** → tap **Cash withdrawal → Transfer**.
  3. Amount **1000** → **Transaction cost (optional)** 29 → From **SIM 1 M-Pesa**, To **Cash** → Save.
- **Expected:**
  - SIM 1 M-Pesa goes **down by 1,029**.
  - Cash goes **up by 1,000**.
  - Spending goes **up by 29 only**.
  - Income doesn't change.
- **Actual:** SIM 1 before ____ after ____ · Cash before ____ after ____ · Spending before ____ after ____
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Also covered by automated test "cash withdrawal on SIM 2: SIM 2 M-Pesa -> Cash, fee kept", and by the Ledger tests.

### C8 · Cash deposit: Cash → M-Pesa [TEST ACCOUNT]
- **Steps:** **Add** → **Income** → tap **Cash deposit → Transfer** → Amount 400 → From **Cash** → To **SIM 2 M-Pesa** → Save.
- **Expected:** Cash drops by 400 and SIM 2 rises by 400. Income doesn't change.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C9 · Transfers filter [TEST ACCOUNT]
- **Steps:** Open **Transactions** → tap the **Transfers** filter.
- **Expected:** The C5, C7 and C8 transfers (and any savings) are listed. The C3 expense and the C4 income are not.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C10 · Transfers are not spending or income [TEST ACCOUNT]
- **Steps:** Compare Home's **Spending** and **Income** with the totals of C3, C4 and the C7 fee only.
- **Expected:** Spending = 300 + 29 = 329, and Income = 2,000. Assumes the test login started empty.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C11 · Edit a transfer, keeping it a transfer [TEST ACCOUNT]
- **Steps:** Open the C5 transfer → change Description to "Line top-up" → **Save changes**.
- **Expected:** It saves. It's still a SIM 1 → SIM 2 transfer, and the balances are unchanged.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Also covered by automated test "a transfer edited as a transfer keeps both ids".

### C12 · Edit a transfer into an expense [TEST ACCOUNT]
- **Steps:** Open the C5 transfer → tap **Expense** → pick **Food** → **Save changes**.
- **Expected:**
  - It saves without error. This is the bug fixed earlier today.
  - It now counts 500 as spending from SIM 1.
  - SIM 2 no longer receives the 500.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Also covered by automated test "SIM 1 -> SIM 2 transfer changed to Expense drops toAccountId".

### C13 · Edit a transfer into income or a refund [TEST ACCOUNT]
- **Steps:**
  1. Create another SIM 1 → SIM 2 transfer of 100.
  2. Open it → **Income** → **Salary** → Save.
  3. Create one more → **Refund** → pick a category → Save.
- **Expected:** Both save without error. Each shows as income or refund respectively.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Also covered by the automated Income and Refund versions of the C12 test.

### C14 · Savings contribution to Ziidi ("To savings") [TEST ACCOUNT]
- **Steps:** **Add** → **To savings** → Amount 50 → From **SIM 2 M-Pesa** → Save.
- **Expected:**
  - SIM 2 M-Pesa drops by 50 and **Ziidi (SIM 2)** rises by 50.
  - Ziidi (SIM 1) doesn't change.
  - It isn't counted as spending.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C15 · Savings withdrawal from Ziidi ("From savings") [TEST ACCOUNT]
- **Steps:** **Add** → **From savings** → Amount 20 → **Moved to**: SIM 2 M-Pesa → Save.
- **Expected:** Ziidi (SIM 2) drops by 20 and SIM 2 M-Pesa rises by 20. It isn't counted as income.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### C16 · Fuliza borrowing and repayment
- **Steps:** None in this build.
- **Expected:** The form can't yet record a Fuliza draw or link a repayment to a Fuliza account. That's planned for the separate Fuliza stage, which needs your approval.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [x] Blocked
- **Notes / evidence:** Blocked: not in this build's UI. The rules and Ledger handling are covered by automated tests ("Fuliza draw (loan -> M-Pesa) by ids", "Fuliza repayment into the loan account", "a Fuliza repayment reduces its loan").

### C17 · Older (legacy) transactions still display correctly (real account, read only)
- **Steps:** In Transactions, find an older **cash withdrawal**, a **Ziidi** entry and an ordinary expense. Open each one, then back out without saving.
- **Expected:** Each shows the same type, amount, category and account (M-Pesa, Cash) as before the update. Nothing crashes.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

---

## D. SMS and permissions

### D1 · SMS detection setting, view only (real account)
- **Steps:** **Settings** → look at **Automatic Transaction Detection**. **Don't** toggle it, and don't tap any import or scan button.
- **Expected:** The switch shows the same state as before the update, and the permission status is shown.
- **Actual:** Switch on / off: ____
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** If it's on, new M-Pesa SMS that arrive while the app is open are still saved automatically, exactly as before this update. This is normal app behaviour, not a historical import.

### D2 · Receiving SIM is recorded
- **Steps:** Only if detection was already on and a **real** new M-Pesa SMS arrives naturally on one of your SIMs: open that new transaction.
- **Expected:**
  - The transaction is linked to the SIM that received the SMS (for example SIM 2 M-Pesa), provided accounts are set up on that login.
  - Without accounts, the SIM is still recorded, but no account is guessed.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Don't send yourself money just to test this. If no SMS arrives naturally, mark this **Blocked**. Also covered by automated test "expense on SIM 2 goes to SIM 2 M-Pesa".

### D3 · No historical import
- **Steps:** After opening the app, check the newest transactions in your real account.
- **Expected:** No batch of old SMS appears. Only SMS that arrive after detection was on are added.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### D4 · No new permission requests
- **Steps:** Use the app normally.
- **Expected:** The app doesn't ask for any new permission. SMS, notifications and biometrics were already granted earlier.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** If Android asks for a permission, tap **Don't allow** and write down which one. Tell Claude before granting anything new.

---

## E. Security and regression

### E1 · PIN unlock
- **Steps:** Close PennyWise from Recents, reopen it and enter your PIN.
- **Expected:** The lock screen appears and the correct PIN opens the app. A wrong PIN is refused.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### E2 · Fingerprint or face unlock
- **Steps:** Reopen the app and use your fingerprint or face.
- **Expected:** The app unlocks without the PIN.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### E3 · Lock after switching away
- **Steps:** Check **Settings → App Lock → Lock after leaving the app**. Open another app for longer than that time, then return to PennyWise.
- **Expected:** PennyWise asks to unlock again.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### E4 · Privacy cover in Recents
- **Steps:** Open the Recent apps view while PennyWise is open.
- **Expected:** PennyWise's preview is covered, so no amounts are visible.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### E5 · Google sign-in still works
- **Steps:** Only once you've finished the test login: **Settings → Sign out**, then sign in with **Google**.
- **Expected:** You're back in your real account with your data. No errors appear.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:** Signing out may also clear App Lock on this phone (by design). If so, set your PIN again.

### E6 · Budgets screen
- **Steps:** Open **Budgets**. View the current month. **Don't change it** on your real account.
- **Expected:** The current budget and progress show correctly.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### E7 · Categories and charts
- **Steps:** View the spending-by-category section and any charts.
- **Expected:** The categories and totals look as before. Transfers and savings aren't counted as spending.
- **Actual:**
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

### E8 · Problems log
- **Steps:** Throughout testing, write down anything wrong here.
- **Expected:** No crashes, save errors, incorrect balances, duplicate entries or unexpected SIM/account assignments.
- **Actual:**
  - Crashes:
  - Save errors (exact message):
  - Wrong balances:
  - Duplicates:
  - Wrong account / SIM:
- **Status:** [ ] Not tested  [ ] Pass  [ ] Fail  [ ] Blocked
- **Notes / evidence:**

---

## F. Results summary

Fill this in when you're done. A1, A2 and A3 already pass from the automated pre-install checks. C16 is blocked because the feature isn't in this build.

| Group | Total | Pass | Fail | Blocked | Not tested |
|---|---|---|---|---|---|
| A. Installation and startup | 5 | 3 | | | 2 |
| B. Accounts and dashboard | 10 | | | | 10 |
| C. Transactions and transfers | 17 | | | 1 | 16 |
| D. SMS and permissions | 4 | | | | 4 |
| E. Security and regression | 8 | | | | 8 |
| **Total** | **44** | **3** | | **1** | **40** |

**Tested by:** __________ · **Date:** __________ · **Overall result:** Pass / Fail / Needs fixes
