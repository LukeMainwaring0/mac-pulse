#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="Mac Pulse"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.lukemainwaring.mac-pulse}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-LukeMainwaring0/mac-pulse}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mac-pulse-notary}"
VERSION="${1:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
PUBLISH="${2:-}"

usage() {
  echo "usage: BUILD_NUMBER=<number> DEVELOPER_ID_APPLICATION=<identity> $0 <version> [--publish]" >&2
}

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" || -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  usage
  exit 2
fi

if [[ "$DEVELOPER_ID_APPLICATION" != "Developer ID Application:"* ]]; then
  echo "DEVELOPER_ID_APPLICATION must name a Developer ID Application certificate, not an Apple Development certificate." >&2
  exit 2
fi

if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null; then
  echo "Developer ID Application identity is not installed in the Keychain: $DEVELOPER_ID_APPLICATION" >&2
  exit 2
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Notarization profile '$NOTARY_PROFILE' is missing or invalid." >&2
  exit 2
fi

for TOOL in codesign ditto hdiutil xcrun; do
  command -v "$TOOL" >/dev/null || { echo "Missing required tool: $TOOL" >&2; exit 1; }
done

SPARKLE_TOOLS_ROOT="${TMPDIR%/}/mac-pulse-swiftpm-build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_TOOLS_ROOT/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "Sparkle release tools are missing. Run 'swift package resolve' first." >&2
  exit 1
fi

RELEASE_ROOT="$ROOT_DIR/dist/releases/$VERSION"
FEED_DIR="$RELEASE_ROOT/feed"
STAGING_DIR="$RELEASE_ROOT/dmg"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
ZIP_PATH="$FEED_DIR/Mac-Pulse-$VERSION.zip"
DMG_PATH="$RELEASE_ROOT/Mac-Pulse-$VERSION.dmg"
APPCAST_PATH="$RELEASE_ROOT/appcast.xml"

rm -rf "$RELEASE_ROOT"
mkdir -p "$FEED_DIR" "$STAGING_DIR"

APP_VERSION="$VERSION" \
APP_BUILD="$BUILD_NUMBER" \
MAC_PULSE_ARCHS="arm64,x86_64" \
CODESIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  "$ROOT_DIR/script/build_and_run.sh" --package

codesign --verify --strict --verbose=2 "$APP_BUNDLE"
ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/InternetSpeed")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || {
  echo "Release executable is not universal: $ARCHS" >&2
  exit 1
}

# Submit a Developer ID-signed archive, then staple the accepted ticket to the app.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RELEASE_ROOT/notarization.zip"
xcrun notarytool submit "$RELEASE_ROOT/notarization.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
rm "$RELEASE_ROOT/notarization.zip"

# The update archive is generated after stapling so Sparkle distributes the
# exact Gatekeeper-ready app users receive from the disk image.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
codesign --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

"$GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION/" \
  --link "https://github.com/$GITHUB_REPOSITORY" \
  --maximum-versions 10 \
  -o "$APPCAST_PATH" \
  "$FEED_DIR"

spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

if [[ "$PUBLISH" == "--publish" ]]; then
  command -v gh >/dev/null || { echo "GitHub CLI is required to publish." >&2; exit 1; }
  gh auth status --hostname github.com >/dev/null
  if ! gh repo view "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh repo create "$GITHUB_REPOSITORY" \
      --public \
      --add-readme \
      --description "Mac Pulse — a quiet, native macOS menu-bar system monitor" \
      --disable-wiki
  fi
  gh release create "v$VERSION" \
    --repo "$GITHUB_REPOSITORY" \
    --title "Mac Pulse $VERSION" \
    --generate-notes \
    "$DMG_PATH" \
    "$ZIP_PATH" \
    "$APPCAST_PATH"
fi

echo "Release ready: $RELEASE_ROOT"
