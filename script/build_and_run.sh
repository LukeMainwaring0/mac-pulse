#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Mac Pulse"
LEGACY_APP_NAME="Internet Speed"
PROCESS_NAME="InternetSpeed"
BUNDLE_ID="com.lukemainwaring.internetspeed"
MIN_SYSTEM_VERSION="13.0"
APP_VERSION="${APP_VERSION:-2.6.9}"
APP_BUILD="${APP_BUILD:-73}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/LukeMainwaring0/mac-pulse/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-p7DmSvt5BWtBXlPV7LllvQnKJfsbYcZwx0xL3GU8pCI=}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
BUILD_CACHE_ROOT="${MAC_PULSE_BUILD_ROOT:-${TMPDIR%/}/mac-pulse-swiftpm-build}"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icon"
ICON_INFO_PLIST="$BUILD_CACHE_ROOT/AppIcon-Info.plist"

CONFIGURATION="debug"
if [[ "$MODE" == "--install" || "$MODE" == "install" || "$MODE" == "--package" || "$MODE" == "package" ]]; then
  CONFIGURATION="release"
fi

cd "$ROOT_DIR"
mkdir -p "$BUILD_CACHE_ROOT/clang-module-cache" "$BUILD_CACHE_ROOT/swiftpm-module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE_ROOT/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE_ROOT/swiftpm-module-cache"

SWIFT_BUILD=(swift build --disable-sandbox -c "$CONFIGURATION" --scratch-path "$BUILD_CACHE_ROOT")
REQUESTED_ARCHS=()
if [[ -n "${MAC_PULSE_ARCHS:-}" ]]; then
  IFS=',' read -r -a REQUESTED_ARCHS <<<"$MAC_PULSE_ARCHS"
fi
if [[ ${#REQUESTED_ARCHS[@]} -gt 1 ]]; then
  # Build each slice with SwiftPM's native builder. Passing several --arch
  # options delegates to SwiftBuild, whose compiler discovery can hang.
  ARCH_BINARIES=()
  BUILD_BIN_PATH=""
  for ARCH in "${REQUESTED_ARCHS[@]}"; do
    # Separate scratch paths keep one slice from overwriting the other.
    ARCH_BUILD=(swift build --disable-sandbox -c "$CONFIGURATION" --scratch-path "$BUILD_CACHE_ROOT/arch-$ARCH" --arch "$ARCH")
    "${ARCH_BUILD[@]}"
    ARCH_BIN_PATH="$("${ARCH_BUILD[@]}" --show-bin-path)"
    ARCH_BINARIES+=("$ARCH_BIN_PATH/$PROCESS_NAME")
    if [[ -z "$BUILD_BIN_PATH" ]]; then BUILD_BIN_PATH="$ARCH_BIN_PATH"; fi
  done
  mkdir -p "$BUILD_CACHE_ROOT/universal"
  BUILD_BINARY="$BUILD_CACHE_ROOT/universal/$PROCESS_NAME"
  /usr/bin/lipo -create "${ARCH_BINARIES[@]}" -output "$BUILD_BINARY"
else
  if [[ ${#REQUESTED_ARCHS[@]} -eq 1 ]]; then SWIFT_BUILD+=(--arch "${REQUESTED_ARCHS[0]}"); fi
  "${SWIFT_BUILD[@]}"
  BUILD_BIN_PATH="$("${SWIFT_BUILD[@]}" --show-bin-path)"
  BUILD_BINARY="$BUILD_BIN_PATH/$PROCESS_NAME"
fi
SPARKLE_FRAMEWORK="$BUILD_BIN_PATH/Sparkle.framework"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not produced by SwiftPM" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# SwiftPM records the deployment target as the SDK version, which makes
# macOS run the app in compatibility mode without Liquid Glass. Record the
# SDK the app was actually built against.
BUILT_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
/usr/bin/vtool -set-build-version macos "$MIN_SYSTEM_VERSION" "$BUILT_SDK_VERSION" -replace -output "$APP_BINARY" "$APP_BINARY"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"

xcrun actool "$ICON_SOURCE" \
  --compile "$APP_RESOURCES" \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_INFO_PLIST"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
</dict>
</plist>
PLIST

# This workspace is File Provider-backed, which can attach Finder metadata to
# newly created bundles. Strip it before signing so strict verification stays
# clean after the bundle is copied into /Applications.
xattr -cr "$APP_BUNDLE"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
else
  SIGN_ARGS=(--verbose --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
  SPARKLE_VERSION="$APP_FRAMEWORKS/Sparkle.framework/Versions/B"
  codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION/Autoupdate"
  codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION/Updater.app"
  codesign "${SIGN_ARGS[@]}" "$APP_FRAMEWORKS/Sparkle.framework"
  codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
    open_app
    ;;
  --debug|debug)
    pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
    open_app
    sleep 3
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  --measure|measure)
    "$APP_BINARY" --measure-once
    ;;
  --stats|stats)
    "$APP_BINARY" --system-stats
    ;;
  --install|install)
    pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
    INSTALL_PATH="/Applications/$APP_NAME.app"
    LEGACY_INSTALL_PATH="/Applications/$LEGACY_APP_NAME.app"
    rm -rf "$INSTALL_PATH"
    /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_PATH"
    xattr -cr "$INSTALL_PATH"
    /usr/bin/open -n "$INSTALL_PATH"
    sleep 3
    pgrep -x "$PROCESS_NAME" >/dev/null
    if [[ -d "$LEGACY_INSTALL_PATH" ]]; then
      rm -rf "$LEGACY_INSTALL_PATH"
    fi
    ;;
  --package|package)
    codesign --verify --strict --verbose=2 "$APP_BUNDLE"
    echo "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--measure|--stats|--install|--package]" >&2
    exit 2
    ;;
esac
