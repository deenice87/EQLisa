#!/bin/zsh
# Erzeugt build/EQLisa-<version>.dmg zum Weitergeben.
set -e
cd "$(dirname "$0")"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/EQLisa-$VERSION.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R build/EQLisa.app "$STAGE/"
ln -s /Applications "$STAGE/Programme"
cp Resources/DMG-LIESMICH.txt "$STAGE/Bitte zuerst lesen.txt"

# Volume-Icon
cp build/EQLisa.app/Contents/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

hdiutil create -volname "EQLisa $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov build/tmp.dmg >/dev/null
MOUNT=$(hdiutil attach build/tmp.dmg -nobrowse -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
if command -v SetFile >/dev/null; then SetFile -a C "$MOUNT"; fi
hdiutil detach "$MOUNT" -quiet
hdiutil convert build/tmp.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f build/tmp.dmg
rm -rf "$STAGE"
echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"
