#!/bin/sh
# Compila, assembla ChargeLimit.app, firma ad-hoc e produce .zip e .dmg.
# Usa swiftc diretto: lo `swift build` dei Command Line Tools 14.3 su macOS 26 fallisce
# cercando la PlatformPath (che esiste solo con Xcode). Package.swift resta valido per toolchain aggiornate.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
DIST="$ROOT/dist"
APP="$DIST/ChargeLimit.app"
DMG="$DIST/ChargeLimit.dmg"
ZIP="$DIST/ChargeLimit.zip"
TARGET="arm64-apple-macos13"
SWIFTC="xcrun swiftc -O -target $TARGET"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

$SWIFTC -module-name SMCKit -parse-as-library \
  -emit-module -emit-module-path "$BUILD/SMCKit.swiftmodule" \
  -emit-library -static -o "$BUILD/libSMCKit.a" "$ROOT"/Sources/SMCKit/*.swift

$SWIFTC -I "$BUILD" -L "$BUILD" -lSMCKit -framework IOKit \
  "$ROOT/Sources/charge-limit-helper/main.swift" -o "$BUILD/charge-limit-helper"

$SWIFTC -module-name ChargeLimit -parse-as-library -I "$BUILD" -L "$BUILD" -lSMCKit -framework IOKit \
  "$ROOT"/Sources/ChargeLimit/*.swift -o "$BUILD/ChargeLimit"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ChargeLimit" "$BUILD/charge-limit-helper" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/install.sh" "$ROOT/Resources/uninstall.sh" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Firma ad-hoc: prima l'eseguibile annidato con identificativo proprio, poi il bundle
codesign --force --sign - --identifier com.alessiocardelli.chargelimit.helper \
  "$APP/Contents/MacOS/charge-limit-helper"
codesign --force --sign - "$APP"

# Zip: un solo "Apri comunque" (sull'app), contro i due del dmg. ditto conserva firma e attributi del bundle
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Charge Limit" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --force --sign - "$DMG"

echo "app: $APP"
echo "zip: $ZIP"
echo "dmg: $DMG"
