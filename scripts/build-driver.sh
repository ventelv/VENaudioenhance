#!/bin/zsh
# Builds build/VENMic.driver (universal, ad-hoc signed).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/build/VENMic.driver"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$ROOT/Driver/VENMic/Info.plist" "$OUT/Contents/Info.plist"
clang -bundle -O2 -Wall -Wno-unused-parameter -mmacosx-version-min=13.0 \
  -arch arm64 -arch x86_64 \
  -framework CoreAudio -framework CoreFoundation \
  -o "$OUT/Contents/MacOS/VENMic" "$ROOT/Driver/VENMic/VENMic.c"
codesign --force --sign "${VEN_SIGN_IDENTITY:--}" "$OUT"
echo "Built $OUT"
