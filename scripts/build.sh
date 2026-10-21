#!/bin/sh
# Compila, assembla BatteryGuard.app, firma ad-hoc e produce .zip e .dmg,
# più il pacchetto versionato in dist/release (dmg, zip, SHA256SUMS).
# Usa swiftc diretto: lo `swift build` dei Command Line Tools 14.3 su macOS 26 fallisce
# cercando la PlatformPath (che esiste solo con Xcode). Package.swift resta valido per toolchain aggiornate.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
DIST="$ROOT/dist"
NAME="BatteryGuard"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
APP="$DIST/$NAME.app"
DMG="$DIST/$NAME.dmg"
ZIP="$DIST/$NAME.zip"
RELEASE="$DIST/release"
TARGET="arm64-apple-macos13"
SWIFTC="xcrun swiftc -O -target $TARGET"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

$SWIFTC -module-name SMCKit -parse-as-library \
  -emit-module -emit-module-path "$BUILD/SMCKit.swiftmodule" \
  -emit-library -static -o "$BUILD/libSMCKit.a" "$ROOT"/Sources/SMCKit/*.swift

$SWIFTC -I "$BUILD" -L "$BUILD" -lSMCKit -framework IOKit \
  "$ROOT/Sources/batteryguard-helper/main.swift" -o "$BUILD/batteryguard-helper"

$SWIFTC -module-name BatteryGuard -parse-as-library -I "$BUILD" -L "$BUILD" -lSMCKit -framework IOKit \
  "$ROOT"/Sources/BatteryGuard/*.swift -o "$BUILD/BatteryGuard"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/BatteryGuard" "$BUILD/batteryguard-helper" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/install.sh" "$ROOT/Resources/uninstall.sh" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Firma ad-hoc: prima l'eseguibile annidato con identificativo proprio, poi il bundle
codesign --force --sign - --identifier com.alessiocardelli.batteryguard.helper \
  "$APP/Contents/MacOS/batteryguard-helper"
codesign --force --sign - "$APP"

# Zip: un solo "Apri comunque" (sull'app), contro i due del dmg. ditto conserva firma e attributi del bundle
ditto -c -k --keepParent "$APP" "$ZIP"

# Dmg con finestra di installazione curata (sfondo, posizioni, icona del volume) scritta da dmgbuild
# direttamente nel .DS_Store: niente AppleScript, quindi nessun permesso di automazione su Finder.
# dmgbuild vive in un venv dentro .build, creato al primo uso.
VENV="$ROOT/.build/dmgbuild-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==1.6.7"
fi
xcrun swiftc -O -target $TARGET "$ROOT/scripts/tools/make-dmg-background.swift" -o "$BUILD/make-dmg-background"
# Produce background.png e background@2x.png: dmgbuild li unisce in un TIFF multi-risoluzione
"$BUILD/make-dmg-background" "$BUILD/background"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" \
  -D app="$APP" -D background="$BUILD/background.png" -D icon="$ROOT/Resources/AppIcon.icns" \
  "$NAME" "$DMG" >/dev/null
codesign --force --sign - "$DMG"

# Pacchetto da pubblicare: stessi file con la versione nel nome e checksum da mettere nella pagina di download
mkdir -p "$RELEASE"
cp "$DMG" "$RELEASE/$NAME-$VERSION.dmg"
cp "$ZIP" "$RELEASE/$NAME-$VERSION.zip"
(cd "$RELEASE" && shasum -a 256 "$NAME-$VERSION.dmg" "$NAME-$VERSION.zip" > SHA256SUMS)

echo "app: $APP"
echo "zip: $ZIP"
echo "dmg: $DMG"
echo "release $VERSION: $RELEASE"
