#!/bin/bash
# Compile MLX's Metal kernels into a standalone mlx.metallib and drop it next to the
# built binaries.
#
# Why this exists
# ---------------
# `swift build` has no Metal compilation rule. Xcode's build system does: it finds the
# .metal files in mlx-swift's Cmlx target and emits a default.metallib into a SwiftPM
# resource bundle. That difference is the whole reason people claim MLX needs xcodebuild.
#
# It doesn't. MLX looks for its kernels in this order (Cmlx/mlx/mlx/backend/metal/device.cpp,
# load_default_library):
#
#   1. mlx.metallib           colocated with the binary   <- what this script produces
#   2. Resources/mlx.metallib colocated with the binary
#   3. default.metallib       inside an mlx-swift_Cmlx.bundle
#   4. Resources/default.metallib
#   5. the literal path "default.metallib"
#
# Option 1 is checked first and needs no bundle, so a prebuilt metallib sitting beside a
# plain `swift build` binary wins before the SwiftPM-bundle path is ever consulted.
#
# MLX runs in JIT mode here, so only the kernels that cannot be JIT-compiled are in this
# library (9 .metal files); everything else is generated at runtime from strings embedded
# in the C++.
#
# Usage: Scripts/build-metallib.sh [output-dir ...]
#        default output dirs: .build/debug .build/release
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMLX="$REPO/.build/checkouts/mlx-swift/Source/Cmlx"
GEN="$CMLX/mlx-generated/metal"

if [ ! -d "$GEN" ]; then
  echo "error: $GEN not found. Run 'swift build --target MoxSpeakNative' first." >&2
  exit 1
fi

# Metal 3.1 is the version macOS 14 / iOS 17 ship. Metal libraries are forward
# compatible, so a 3.1 library loads on every later OS; compiling against a newer
# language version would strand macOS 14. Deliberately the floor, not the ceiling.
STD="metal3.1"
MIN="14.0"

OUT_DIRS=("$@")
if [ ${#OUT_DIRS[@]} -eq 0 ]; then
  OUT_DIRS=("$REPO/.build/debug" "$REPO/.build/release")
  # MLX resolves the metallib relative to whichever binary it is linked into, so a test
  # bundle needs its own copy beside the .xctest executable.
  while IFS= read -r bundle; do
    OUT_DIRS+=("$bundle/Contents/MacOS")
  done < <(find "$REPO/.build" -maxdepth 3 -name '*.xctest' -type d 2>/dev/null)
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCES=(
  "$GEN/arg_reduce.metal"
  "$GEN/conv.metal"
  "$GEN/gemv.metal"
  "$GEN/layer_norm.metal"
  "$GEN/random.metal"
  "$GEN/rms_norm.metal"
  "$GEN/rope.metal"
  "$GEN/scaled_dot_product_attention.metal"
  "$GEN/steel/attn/kernels/steel_attention.metal"
)

echo "compiling ${#SOURCES[@]} metal sources (-std=$STD, min macOS $MIN)"
AIRS=()
for src in "${SOURCES[@]}"; do
  air="$WORK/$(basename "${src%.metal}").air"
  xcrun -sdk macosx metal \
    -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-c++17-extensions \
    -fno-fast-math \
    -std="$STD" \
    -mmacosx-version-min="$MIN" \
    -I "$GEN" \
    -I "$CMLX/mlx" \
    -c "$src" -o "$air"
  AIRS+=("$air")
done

xcrun -sdk macosx metallib "${AIRS[@]}" -o "$WORK/mlx.metallib"
SIZE=$(du -h "$WORK/mlx.metallib" | cut -f1)

for dir in "${OUT_DIRS[@]}"; do
  mkdir -p "$dir"
  cp "$WORK/mlx.metallib" "$dir/mlx.metallib"
  echo "wrote $dir/mlx.metallib ($SIZE)"
done
