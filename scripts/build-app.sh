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
# Licence notices for everything inside the app.
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/VEN Audio Enhance.txt"
cp Sources/CRNNoise/COPYING "$APP/Contents/Resources/Licenses/RNNoise.txt"
# App icon, drawn by scripts/make-icon.swift.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
  sips -z $px $px Resources/icon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) Resources/icon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Studio noise engine, if scripts/build-deepfilter.sh has been run.
if [[ -f build/deps/out/libdf.dylib ]]; then
  mkdir -p "$APP/Contents/Resources/DeepFilterNet"
  cp build/deps/out/libdf.dylib build/deps/out/DeepFilterNet3_onnx.tar.gz "$APP/Contents/Resources/DeepFilterNet/"
  cp build/deps/DeepFilterNet/LICENSE-MIT "$APP/Contents/Resources/Licenses/DeepFilterNet (MIT).txt"
  cp build/deps/DeepFilterNet/LICENSE-APACHE "$APP/Contents/Resources/Licenses/DeepFilterNet (Apache-2.0).txt"
fi
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
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
	<key>NSMicrophoneUsageDescription</key><string>VEN Audio Enhance cleans up your microphone and passes it to other apps through VEN Enhanced Mic.</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>Audio or video recording</string>
			<key>CFBundleTypeRole</key><string>Editor</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/VENMic.driver"
# Hardened Runtime: no injected libraries or debugger attach, so nothing can borrow the app's mic permission.
ENTITLEMENTS="$ROOT/Resources/VENApp.entitlements"
[[ -f "$APP/Contents/Resources/DeepFilterNet/libdf.dylib" ]] && ENTITLEMENTS="$ROOT/Resources/VENApp-studio.entitlements"
RUNTIME=(--options runtime --entitlements "$ENTITLEMENTS")
[[ -f "$APP/Contents/Resources/DeepFilterNet/libdf.dylib" ]] && codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/DeepFilterNet/libdf.dylib"
codesign --force --sign "$IDENTITY" "${RUNTIME[@]}" "$APP/Contents/MacOS/ven-cli"
codesign --force --sign "$IDENTITY" "${RUNTIME[@]}" "$APP"
echo "Built $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  DEST=/Applications
  [[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  pkill -f "VEN Audio Enhance.app/Contents/MacOS/VEN Audio Enhance" 2>/dev/null || true
  rm -rf "$DEST/VEN Audio Enhance.app"
  cp -R "$APP" "$DEST/"
  echo "Installed to $DEST/VEN Audio Enhance.app"
fi
