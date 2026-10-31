# Release signing (Google Play upload key)

Release builds are signed with your **upload key** when `android/key.properties`
exists. Without it, they fall back to the debug key and the build prints a
warning. That's fine for testing on your own phone, but Google Play rejects
it. If `key.properties` names a keystore that doesn't exist, or leaves out a
value, the build stops with a clear message. The build never prints the
passwords.

The keystore (`*.jks`, `*.keystore`) and `key.properties` are ignored by Git
everywhere in the project. Still, keep the keystore **outside** the project
folder.

> **Never lose the keystore or its password.** Keep a backup of both in a
> second safe place, such as a password manager plus encrypted cloud storage
> or a USB drive. If the upload key is lost, you have to ask Google to reset
> it, which takes days.

All commands below are for **PowerShell** on your PC.

## 1. Create the upload key (once)

```powershell
New-Item -ItemType Directory -Force "$HOME\keys" | Out-Null
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v `
  -keystore "$HOME\keys\pennywise-upload.jks" -alias upload `
  -keyalg RSA -keysize 2048 -validity 10000
```

It asks you to:
1. Enter a keystore password: choose a strong one (16+ characters) and save it in your password manager. Nothing shows while you type; that's normal.
2. Re-enter it.
3. Answer the name questions: your name, then optionally organisation and city. Country code: `KE`.
4. Type `yes` to confirm.

Modern keytool uses the same password for the key, so you only need the one.

## 2. Create `android/key.properties` (without showing the password)

```powershell
$secure = Read-Host "Keystore password" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
$store = "$HOME\keys\pennywise-upload.jks" -replace '\\', '/'
@"
storeFile=$store
storePassword=$plain
keyAlias=upload
keyPassword=$plain
"@ | Set-Content -Encoding ascii "$HOME\Desktop\pennywise\android\key.properties"
Remove-Variable plain, secure
```

Check that Git ignores it. The command should print the file's path:

```powershell
git -C "$HOME\Desktop\pennywise" check-ignore android/key.properties
```

## 3. Build and verify the bundle

```powershell
cd "$HOME\Desktop\pennywise"
flutter build appbundle --release
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -printcert `
  -jarfile build\app\outputs\bundle\release\app-release.aab
```

The **Owner** line must show your name, not `CN=Android Debug`. The file to upload is `build\app\outputs\bundle\release\app-release.aab`.

## 4. The upload key's SHA-1 (public; safe to share)

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -list -v `
  -keystore "$HOME\keys\pennywise-upload.jks" -alias upload | Select-String "SHA1:"
```

It asks for the keystore password. Copy the `SHA1: AB:CD:…` line. Fingerprints are public, so you can paste it to Claude to add to Firebase once you approve.

## 5. Google sign-in in Play builds

Google Play re-signs the app with its own **app signing key**. Both SHA-1 fingerprints must be in Firebase (Project settings › Your apps › Android `com.codewithmeguru.pennywise` › Add fingerprint), or Google sign-in fails for Play installs:

- **Upload key:** from step 4.
- **App signing key:** Play Console › Test and release › Setup › App integrity › App signing, after your first upload.

No new `google-services.json` is needed for these: the fingerprints only tell Firebase which signed apps may sign in.
