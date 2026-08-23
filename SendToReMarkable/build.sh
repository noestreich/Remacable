#!/bin/bash
# Baut SendToReMarkable.app aus dem SwiftPM-Paket.
set -euo pipefail

cd "$(dirname "$0")"
APP="SendToReMarkable.app"
BUNDLE_ID="de.oestreich.SendToReMarkable"
VERSION="1.0"

echo "==> Kompilieren (release)"
swift build -c release

echo "==> Bundle zusammenbauen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/SendToReMarkable" "$APP/Contents/MacOS/SendToReMarkable"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SendToReMarkable</string>
  <key>CFBundleDisplayName</key><string>Send to reMarkable</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SendToReMarkable</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Menueleisten-App: kein Dock-Icon -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signieren, sonst beschwert sich macOS beim Start
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    (Signieren übersprungen)"

# Damit der Finder das neue Icon nicht aus dem Zwischenspeicher zeigt
touch "$APP"

echo "==> Fertig: $(pwd)/$APP"
echo
echo "Starten:      open \"$(pwd)/$APP\""
echo "Installieren: cp -R \"$(pwd)/$APP\" /Applications/"
