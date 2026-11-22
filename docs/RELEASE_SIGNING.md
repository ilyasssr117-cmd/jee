# Release signing (Android)

Release builds are never signed with the debug key.

## Local
1. Generate a keystore outside the repo (or in `android/` — `*.jks` is git-ignored):
   `keytool -genkey -v -keystore ~/vxtube-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias vxtube`
2. Create `android/key.properties` (git-ignored):
   ```
   storeFile=/absolute/path/vxtube-release.jks
   storePassword=...
   keyAlias=vxtube
   keyPassword=...
   ```
3. `flutter build apk --release`

## CI
Set secrets: `VXTUBE_KEYSTORE_PATH`, `VXTUBE_KEYSTORE_PASSWORD`, `VXTUBE_KEY_ALIAS`, `VXTUBE_KEY_PASSWORD`
(materialize the keystore file from a base64 secret in a prior step).

## Failure mode
A release task invoked without signing configuration fails with a clear
GradleException instead of silently producing a debug-signed artifact.
