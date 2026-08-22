#!/bin/bash
# Richtet send2rm ein: rmapi laden, Droplet bauen, Quellen ueberwachen.
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3)"
LABEL="com.send2rm.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> rmapi herunterladen"
case "$(uname -m)" in
  arm64) ASSET="rmapi-macos-arm64.zip" ;;
  *)     ASSET="rmapi-macos-intel.zip" ;;
esac

mkdir -p "$BASE/bin"
URL="$(curl -fsSL https://api.github.com/repos/ddvk/rmapi/releases/latest \
       | grep -o "https://[^\"]*${ASSET}" | head -1)"
if [ -z "$URL" ]; then
  echo "Download-URL fuer $ASSET nicht gefunden" >&2
  exit 1
fi
echo "    $URL"
TMPZIP="$(mktemp -t rmapi).zip"
curl -fL --progress-bar "$URL" -o "$TMPZIP"
unzip -o -j -q "$TMPZIP" -d "$BASE/bin"
rm -f "$TMPZIP"
chmod +x "$BASE/bin/rmapi"
# Gatekeeper-Quarantaene entfernen, sonst verweigert macOS den Start
xattr -dr com.apple.quarantine "$BASE/bin/rmapi" 2>/dev/null || true
"$BASE/bin/rmapi" version 2>/dev/null | head -1 || true

echo "==> Quellen aus config.toml lesen"
# Eine Zeile pro Quelle: "move<TAB>pfad"
SOURCES="$("$PY" - "$BASE" <<'EOF'
import os, pathlib, sys, tomllib
base = pathlib.Path(sys.argv[1])
cfg = {}
p = base / "config.toml"
if p.exists():
    cfg = tomllib.load(p.open("rb"))
sources = cfg.get("sources") or [{"path": cfg.get("inbox", "~/reMarkable Inbox"), "move": True}]
for s in sources:
    print(f"{'1' if s.get('move', True) else '0'}\t{os.path.expanduser(s['path'])}")
EOF
)"

WATCH_XML=""
FIRST_INBOX=""
while IFS=$'\t' read -r MOVE DIR; do
  [ -z "${DIR:-}" ] && continue
  if [ "$MOVE" = "1" ]; then
    mkdir -p "$DIR/Uploaded" "$DIR/Failed"
    [ -z "$FIRST_INBOX" ] && FIRST_INBOX="$DIR"
    echo "    $DIR  (Watch-Folder)"
  else
    echo "    $DIR  (nur beobachten)"
  fi
  WATCH_XML="$WATCH_XML
    <string>$DIR</string>"
done <<< "$SOURCES"

echo "==> Droplet bauen"
rm -rf "$BASE/Send to reMarkable.app"
sed -e "s|__PYTHON__|$PY|" -e "s|__SCRIPT__|$BASE/send2rm.py|" \
    "$BASE/droplet.applescript" > "$BASE/.droplet.generated.applescript"
osacompile -o "$BASE/Send to reMarkable.app" "$BASE/.droplet.generated.applescript"
rm -f "$BASE/.droplet.generated.applescript"
echo "    $BASE/Send to reMarkable.app"

echo "==> launchd-Agent einrichten"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$BASE/send2rm.py</string>
    <string>--scan</string>
  </array>
  <key>WatchPaths</key>
  <array>$WATCH_XML
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/send2rm.launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/send2rm.launchd.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "    $PLIST geladen"

cat <<EOF

Fertig. Ein Schritt fehlt noch — die einmalige Kopplung mit deinem Konto:

  1. https://my.remarkable.com/device/desktop/connect oeffnen, 8-stelligen Code holen
  2. $BASE/bin/rmapi
     (Code eingeben, dann "exit" — der Token landet in ~/.rmapi)
  3. $PY $BASE/send2rm.py --check

Danach: Datei in "${FIRST_INBOX:-den Watch-Folder}" legen oder aufs Droplet ziehen.
EOF
