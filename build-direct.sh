#!/usr/bin/env bash
#
# Direct swiftc build — bypasses Swift Package Manager entirely.
#
# Use this if `./build.sh` fails at the manifest step with linker errors about
# missing `PackageDescription` / `SwiftVersion` symbols. That means your Command
# Line Tools' SwiftPM library is broken or half-installed — but the Swift
# COMPILER itself is fine, so we compile the app directly against system
# frameworks and skip SwiftPM (and the broken library) completely.
#
# Same result as build.sh: a ./UsageBar.app you can launch. (Tests still need a
# healthy SwiftPM via `swift test` — CI runs those on every push.)
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UsageBar"
BUNDLE_ID="ai.usagebar.personal"
VERSION="1.0.0"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. If you just ran 'xcode-select --install', wait for the"
  echo "'Install Command Line Developer Tools' dialog to finish, then retry."
  exit 1
fi

echo "==> Compiling with swiftc (no SwiftPM, zero dependencies)…"
TMP="$(mktemp -d)"
# Everything compiles as ONE module here, so strip main.swift's cross-module
# `import UsageBarKit` (that import only exists for the SwiftPM library split).
grep -v '^import UsageBarKit' Sources/UsageBar/main.swift > "$TMP/main.swift"

# shellcheck disable=SC2046
swiftc -O -swift-version 5 \
  -framework AppKit -framework Foundation -framework Security -framework CryptoKit \
  $(find Sources/UsageBarKit -name '*.swift') "$TMP/main.swift" \
  -o "$TMP/$APP_NAME"

echo "==> Assembling $APP_NAME.app …"
APP_DIR="./$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$TMP/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "   (codesign skipped — non-fatal)"
echo ""
echo "Done. Launch it with:  open $APP_DIR"
