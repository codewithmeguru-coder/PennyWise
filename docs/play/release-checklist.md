# Google Play release checklist

## Status (checked 31 Oct 2026)
| Check | Result |
|---|---|
| Application ID | `com.codewithmeguru.pennywise` everywhere in the Android build. iOS, macOS and Linux still say `com.example` (not shipped). |
| Version | `1.0.0+1`. Raise `+N` for every upload. |
| Target SDK | 36 (Flutter 3.47). Meets Play's current minimum. |
| Release signing | Set up: `android/key.properties` is used when it exists. **The upload key doesn't exist yet**, so release builds are still debug-signed and Play would reject them. |
| Release bundle | `flutter build appbundle --release` builds. |
| Firebase Android app | Registered for `com.codewithmeguru.pennywise`. |
| SHA-1 registered | **Debug key only** (`8F:31:FE…`). Upload key: missing. Play App Signing key: missing (you get it after the first upload). |
| Login at narrow widths | Tested at 280, 320 and 393, light and dark. |
| SMS disclosure | Updated to name Equity Bank and the SIM. |
| Account deletion | Built: in the app and as a web page (`docs/play/account-deletion.md`). **Needs the rules and page deployed** (your approval). |
| Privacy policy | Working draft in `privacy-policy.md`, and the matching page in `hosting/privacy/` for https://pennywise-b986a.web.app/privacy. Needs your details (the [CONFIRM] items), then deploying. |

## Upload key vs Play App Signing key
- **Upload key:** you create it and keep it. You sign every bundle you upload with it. Its SHA-1 goes into Firebase, so builds you sign yourself can use Google sign-in.
- **App signing key:** Google creates and keeps it when you enrol in Play App Signing (the default for new apps). Google re-signs your app with it, and that's what users install. Its SHA-1 must also go into Firebase, or Google sign-in fails for everyone who installs from Play. You'll find it in Play Console › Test and release › Setup › App integrity › App signing.

## Steps that need you
1. **Create the upload key.** Follow `docs/release-signing.md` step 1.
   - Store the `.jks` file outside the project folder.
   - Keep the passwords in a password manager.
   - Back up both to a second safe place, such as encrypted cloud storage or a USB drive.
2. **Create `android/key.properties`** (step 2). Git already ignores it; check with `git check-ignore android/key.properties`.
3. **Build and verify:** `flutter build appbundle --release`, then `keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab`. The Owner shown should be you, not "Android Debug".
4. **Send me the upload key's SHA-1** (from `keytool -list -v -keystore <path> -alias upload`). It's public, not secret. With your OK, I'll add it to Firebase.
5. **Approve deploying account deletion:** the Firestore rules and the web page (`account-deletion.md`). Then fill the contact email in the page.
6. **Fill in the [CONFIRM] items** in the privacy policy, then publish it at a public URL.
7. **Create a Play Console developer account** ($25, identity verification).
   - New personal accounts must run a **closed test with at least 12 testers for 14 days** before applying for production. Check the current numbers in Play Console.
8. **Create the app in Play Console.** Fill in:
   - store listing
   - content rating
   - target audience
   - ads (none)
   - Data safety
   - financial features declaration
   - **SMS permissions declaration**, with the demo video
9. **Upload the bundle to Closed testing.** Then copy the **app signing key SHA-1** from App integrity and send it to me to add to Firebase.
10. **Test Google sign-in** on a Play-installed build.
11. **Run the closed test** (12+ testers, 14 days), fix issues, then **apply for production**.

## Not yet done
- Account deletion: built; the rules and page must be deployed (blocker until then).
- Upload key and its SHA-1 (blocker).
- App signing key SHA-1 (after the first upload).
- Published privacy policy (blocker).
- Optional: in Google Cloud, restrict the Firebase API key to the Android app and its SHA-1s; Firebase App Check.
