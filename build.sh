#!/bin/zsh
# Baut EQLisa.app in ./build
#   ./build.sh           → nur bauen
#   ./build.sh install   → bauen, nach /Applications kopieren und starten
set -e
cd "$(dirname "$0")"

# Universal-Build: Apple Silicon + Intel
swift build -c release --triple arm64-apple-macosx14.2
swift build -c release --triple x86_64-apple-macosx14.2
APP=build/EQLisa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/EQLisa" \
  .build/arm64-apple-macosx/release/EQLisa \
  .build/x86_64-apple-macosx/release/EQLisa
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App-Icon (.icns) aus Resources/AppIcon-1024.png
# (neu erzeugen nach Änderung der Vorlage: swift Scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon-1024.png)
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon-1024.png "$APP/Contents/Resources/AppIcon-1024.png"   # für das Info-Fenster
codesign --force --sign - "$APP"
echo "✅ $APP gebaut."

if [[ "$1" == "install" ]]; then
  pkill -x EQLisa 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/EQLisa.app
  cp -R "$APP" /Applications/
  open /Applications/EQLisa.app
  echo "✅ Installiert in /Applications und gestartet."
fi
