#!/bin/zsh
# Builds DeepFilterNet's C library (libdf) for the "Studio" noise engine.
# Needs Rust (brew install rust). Puts libdf.dylib and the DeepFilterNet3 model in build/deps/out,
# where ven-cli finds them and scripts/build-app.sh copies them into the app.
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/build/deps/DeepFilterNet"
OUT="$ROOT/build/deps/out"
COMMIT=d375b2d   # tested revision of github.com/Rikorose/DeepFilterNet

if [[ ! -d "$SRC" ]]; then
  git clone https://github.com/Rikorose/DeepFilterNet.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q "$COMMIT"

cd "$SRC"
cargo build --release -p deep_filter --no-default-features --features capi
mkdir -p "$OUT"
cp target/release/libdf.dylib "$OUT/"
install_name_tool -id @rpath/libdf.dylib "$OUT/libdf.dylib"
cp models/DeepFilterNet3_onnx.tar.gz "$OUT/"
codesign --force --sign "${VEN_SIGN_IDENTITY:--}" "$OUT/libdf.dylib"
echo "DeepFilterNet ready in $OUT"
