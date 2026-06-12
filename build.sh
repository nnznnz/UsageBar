#!/usr/bin/env bash
#
# Build UsageBar into a self-contained menu-bar app: ./UsageBar.app
#
# Run this on your Mac (needs the Xcode Command Line Tools — `xcode-select
# --install` if `swift` isn't found). It compiles a release binary with the
# Swift Package Manager (no dependencies are fetched — there are none), wraps it
# in a minimal .app bundle so it launches without a terminal and shows no Dock
# icon, and ad-hoc code-signs it so macOS can remember your "Always Allow"
# keychain choice between launches.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UsageBar"
BUNDLE_ID="ai.usagebar.personal"

# App version. Priority: explicit $VERSION (CI sets it from the git tag) → the
# most recent git tag → a dev placeholder. A leading "v" (as in v1.2.3) is
# stripped so CFBundleShortVersionString is a clean numeric string.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0-dev}"
echo "==> Version: $VERSION"

echo "==> Building release binary (no third-party dependencies)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Build did not produce $BIN_PATH" >&2
  exit 1
fi

APP_DIR="./$APP_NAME.app"
echo "==> Assembling $APP_DIR …"
# NOTE: this fully replaces any existing ./UsageBar.app — it is rebuilt from
# scratch each run, so don't keep hand-edited files or custom signing inside it.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Bundle the app icon if it's been generated (scripts/make-icon.sh).
if [[ -f "Resources/AppIcon.icns" ]]; then
  mkdir -p "$APP_DIR/Contents/Resources"
  cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSSupportsAutomaticTermination</key> <false/>
  <key>NSSupportsSuddenTermination</key>    <false/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code-signing…"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || {
  echo "   (codesign failed — the app will still run, but macOS may re-prompt"
  echo "    for keychain access more often. This is non-fatal.)"
}

echo ""
echo "Done. Launch it with:   open $APP_DIR"
echo "It appears in your menu bar (no Dock icon, no window)."
echo "First run writes a starter config to ~/.config/usagebar/config.json"
