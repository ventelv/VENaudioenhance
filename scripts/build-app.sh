#!/bin/zsh
# Builds "VEN Audio Enhance.app" (with the driver and ven-cli inside) and installs it.
#   scripts/build-app.sh            build + install to /Applications (or ~/Applications)
#   scripts/build-app.sh --no-install
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/build/VEN Audio Enhance.app"
IDENTITY="${VEN_SIGN_IDENTITY:--}"   # set to a Keychain certificate name for a stable signature

cd "$ROOT"
swift build -c release 2>&1 | grep -v "xcrun: error\|could not determine XCTest" || true
"$ROOT/scripts/build-driver.sh" >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VENApp "$APP/Contents/MacOS/VEN Audio Enhance"
cp .build/release/ven-cli "$APP/Contents/MacOS/ven-cli"
cp -R build/VENMic.driver "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>VEN Audio Enhance</string>
	<key>CFBundleIdentifier</key><string>com.ven.audioenhance</string>
	<key>CFBundleName</key><string>VEN Audio Enhance</string>
	<key>CFBundleDisplayName</key><string>VEN Audio Enhance</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
	<key>NSMicrophoneUsageDescription</key><string>VEN Audio Enhance cleans up your microphone and passes it to other apps through VEN Enhanced Mic.</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/VENMic.driver"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/ven-cli"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  DEST=/Applications
  [[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  pkill -f "VEN Audio Enhance.app/Contents/MacOS/VEN Audio Enhance" 2>/dev/null || true
  rm -rf "$DEST/VEN Audio Enhance.app"
  cp -R "$APP" "$DEST/"
  echo "Installed to $DEST/VEN Audio Enhance.app"
fi
