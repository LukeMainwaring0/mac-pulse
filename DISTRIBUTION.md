# Mac Pulse distribution

Mac Pulse remains a menu-bar-only app. Public builds are distributed as a
notarized disk image and update themselves through Sparkle.

## One-time setup

1. Releases are signed with **Developer ID Application: Lightfield, Inc.
   (TYVB4357K2)**, which must be in the login Keychain.
2. Notarization uses an App Store Connect API key stored as the Keychain
   profile `mac-pulse-lightfield`:

   ```sh
   xcrun notarytool store-credentials mac-pulse-lightfield \
     --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER_ID
   ```

   If Apple returns HTTP 403 about a missing agreement, the Account Holder must
   accept the latest agreement at developer.apple.com first.

3. Sign in to GitHub CLI with `gh auth login --hostname github.com`.
4. Releases are attached to the public source repository
   `LukeMainwaring0/mac-pulse`.

The Sparkle EdDSA private key is stored in the login Keychain under
`com.lukemainwaring.mac-pulse`. The public key embedded in the app is safe to
publish. Never export or commit the private key.

## Ship a release

Choose a monotonically increasing build number and run:

```sh
BUILD_NUMBER=10 \
DEVELOPER_ID_APPLICATION="Developer ID Application: Lightfield, Inc. (TYVB4357K2)" \
./script/release.sh 1.2.0 --publish
```

The script builds a universal app, signs Sparkle's nested services in the
required order, enables hardened runtime, notarizes and staples the app and
disk image, signs the update archive with EdDSA, generates `appcast.xml`, runs
Gatekeeper checks, and attaches the artifacts to a GitHub Release.

The app checks this stable feed once per day:

`https://github.com/LukeMainwaring0/mac-pulse/releases/latest/download/appcast.xml`

Do not reuse a version or build number. Keep prior update ZIPs available so
Sparkle can generate useful deltas and retain older feed entries.
