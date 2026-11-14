#!/bin/zsh
# Builds the app and zips it with the licence for a GitHub release: build/VEN-Audio-Enhance.zip.
# Prints the zip's SHA-256 for the release notes.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
scripts/build-app.sh --no-install
STAGE="$ROOT/build/release"
rm -rf "$STAGE" build/VEN-Audio-Enhance.zip
mkdir -p "$STAGE"
ditto "build/VEN Audio Enhance.app" "$STAGE/VEN Audio Enhance.app"
cp LICENSE "$STAGE/LICENSE.txt"
codesign --verify --deep --strict "$STAGE/VEN Audio Enhance.app"
# ditto keeps the code signature intact (zip would not).
ditto -c -k --sequesterRsrc "$STAGE" build/VEN-Audio-Enhance.zip
echo "Version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAGE/VEN Audio Enhance.app/Contents/Info.plist")"
shasum -a 256 build/VEN-Audio-Enhance.zip
