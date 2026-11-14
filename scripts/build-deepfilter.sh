#!/bin/zsh
# Builds DeepFilterNet's C library (libdf) for the "Studio" noise engine.
# Needs Rust (brew install rust). Puts libdf.dylib and the DeepFilterNet3 model in build/deps/out,
# where ven-cli finds them and scripts/build-app.sh copies them into the app.
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/build/deps/DeepFilterNet"
OUT="$ROOT/build/deps/out"
COMMIT=d375b2d8309e0935d165700c91da9de862a99c31   # tested revision of github.com/Rikorose/DeepFilterNet

if [[ ! -d "$SRC" ]]; then
  git clone https://github.com/Rikorose/DeepFilterNet.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q "$COMMIT"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$COMMIT" ]] || { echo "DeepFilterNet isn't at $COMMIT" >&2; exit 1; }

cd "$SRC"
cargo build --release --locked -p deep_filter --no-default-features --features capi
mkdir -p "$OUT"
cp target/release/libdf.dylib "$OUT/"
install_name_tool -id @rpath/libdf.dylib "$OUT/libdf.dylib"
cp models/DeepFilterNet3_onnx.tar.gz "$OUT/"
codesign --force --sign "${VEN_SIGN_IDENTITY:--}" "$OUT/libdf.dylib"
echo "DeepFilterNet ready in $OUT"
