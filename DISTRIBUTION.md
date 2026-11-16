# Mac Pulse distribution

Mac Pulse remains a menu-bar-only app. Public builds are distributed as a
notarized disk image and update themselves through Sparkle.

## One-time setup

1. Install a **Developer ID Application** certificate for the paid Apple
   Developer team in the login Keychain.
2. Create an app-specific Apple ID password, then store notarization credentials:

   ```sh
   xcrun notarytool store-credentials mac-pulse-notary \
     --apple-id "APPLE_ID" \
     --team-id "QCGU85GC22" \
     --password "APP_SPECIFIC_PASSWORD"
   ```

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
DEVELOPER_ID_APPLICATION="Developer ID Application: … (QCGU85GC22)" \
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
