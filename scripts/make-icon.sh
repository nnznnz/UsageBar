#!/usr/bin/env bash
#
# Regenerate the app icon into Resources/AppIcon.icns (+ a viewable 1024 PNG).
# Pure Apple tooling — swift renders the art, sips resizes, iconutil packs it.
# No third-party dependencies, consistent with the rest of UsageBar.
#
#   scripts/make-icon.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
MASTER="$WORK/icon_1024.png"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET" Resources

echo "==> Rendering master PNG…"
swift scripts/make-icon.swift "$MASTER"

echo "==> Building iconset…"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"             "$MASTER" --out "$SET/icon_${s}x${s}.png"    >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$MASTER" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

echo "==> Packing AppIcon.icns…"
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$MASTER" Resources/AppIcon-1024.png    # human-viewable reference / GitHub preview
rm -rf "$WORK"
echo "Done -> Resources/AppIcon.icns"
