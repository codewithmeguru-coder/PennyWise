# Release signing (Google Play upload key)

Release builds are signed with your **upload key** when `android/key.properties`
exists. Without it they fall back to the debug key, which is fine for testing
on your own phone but is rejected by Google Play.

`key.properties`, `*.jks` and `*.keystore` are in `.gitignore`. Never commit
them, and keep a backup of the keystore and its passwords outside this
folder: losing the upload key means asking Google to reset it.

## 1. Create the upload key (once)

Run this in a terminal, then answer the prompts. Choose your own passwords.

```
keytool -genkeypair -v -keystore C:\Users\<you>\keys\pennywise-upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000
```

`keytool` comes with Android Studio: `C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe`.

## 2. Create `android/key.properties`

```
storeFile=C:/Users/<you>/keys/pennywise-upload.jks
storePassword=<store password>
keyAlias=upload
keyPassword=<key password>
```

## 3. Build the bundle for Play

```
flutter build appbundle --release
```

The file is `build/app/outputs/bundle/release/app-release.aab`. Check it is
signed with your key (the Owner line should be yours, not "Android Debug"):

```
keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab
```

## 4. Google sign-in in Play builds

Google Play re-signs the app with its own **app signing key**. Add both SHA-1
fingerprints to Firebase (Project settings › Your apps › Android app ›
Add fingerprint), or Google sign-in fails in the Play version:

- the upload key: `keytool -list -v -keystore <path> -alias upload`
- the app signing key: Play Console › Test and release › App integrity

Then download the new `google-services.json` into `android/app/`.
