#!/bin/bash
# Baut Remacable.app aus dem SwiftPM-Paket.
set -euo pipefail

cd "$(dirname "$0")"
APP="Remacable.app"
BUNDLE_ID="de.oestreich.Remacable"
VERSION="1.0"

echo "==> Kompilieren (release)"
swift build -c release

echo "==> Bundle zusammenbauen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Remacable" "$APP/Contents/MacOS/Remacable"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Remacable</string>
  <key>CFBundleDisplayName</key><string>Remacable</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Remacable</string>
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

# Mit Developer ID signieren, wenn eine im Schluesselbund liegt — nur so laesst
# sich die App spaeter beurkunden (notarisieren). Sonst ad-hoc, dann muss man
# sie beim ersten Start ueber die Systemeinstellungen freigeben.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/')}"

if [ -n "$IDENTITY" ]; then
  echo "==> Signieren: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict "$APP" && echo "    Signatur geprüft"
else
  echo "==> Signieren: ad-hoc (kein Developer-ID-Zertifikat gefunden)"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
    echo "    (Signieren übersprungen)"
fi

# Damit der Finder das neue Icon nicht aus dem Zwischenspeicher zeigt
touch "$APP"

echo "==> Fertig: $(pwd)/$APP"
echo
echo "Starten:      open \"$(pwd)/$APP\""
echo "Installieren: cp -R \"$(pwd)/$APP\" /Applications/"
