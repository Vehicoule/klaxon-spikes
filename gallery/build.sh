#!/usr/bin/env bash
# Build de l'app gallery K2 (Linux/X11) : shim kx_skia natif + zig build-exe.
set -euo pipefail
ROOT=/home/ubuntu/work/Klaxon
SKIA=$ROOT/spikes/w0-graphite-wasm/deps/skia
ZIG=/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig
SDL=/home/ubuntu/work/Klaxon/spikes/k1-sdl/deps/SDL3-build
OUT=$ROOT/gallery/out
mkdir -p "$OUT"
cd "$ROOT"

INC="-I$SKIA -I$SKIA/include -I$SKIA/modules/skunicode/include \
     -I$SKIA/third_party/externals/freetype/include \
     -I$SKIA/third_party/externals/harfbuzz/src \
     -I$SKIA/third_party/externals/icu/source/common \
     -I$SKIA/third_party/externals/vulkanmemoryallocator/include \
     -I$SKIA/third_party/externals/vulkan-headers/include"
FLAGS="-std=c++20 -O2 -fno-exceptions -fno-rtti -DSK_GANESH -DSK_GRAPHITE -DNDEBUG"

for f in kx_skia/src/kx_skia_linux.cpp kx_skia/src/kx_scenes.cpp kx_skia/src/kx_draw.cpp kx_skia/src/kx_a11y_linux.cpp; do
    o="$OUT/$(basename ${f%.cpp}).o"
    [ "$o" -nt "$f" ] || clang++ $FLAGS $INC -I$ROOT/kx_skia/include -c "$f" -o "$o"
done

$ZIG build-exe \
    --dep klaxon -Mroot=gallery/main.zig \
    -Mklaxon=klaxon/src/klaxon.zig \
    -O fast \
    $OUT/kx_skia_linux.o $OUT/kx_scenes.o $OUT/kx_draw.o $OUT/kx_a11y_linux.o \
    -lc \
    /usr/lib/gcc/x86_64-linux-gnu/11/libstdc++.a \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgcc_eh.a \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgcc.a \
    $SKIA/out/linux/libskia.a $SKIA/out/linux/libskparagraph.a \
    $SKIA/out/linux/libskshaper.a $SKIA/out/linux/libskunicode_icu.a \
    $SKIA/out/linux/libskunicode_core.a $SKIA/out/linux/libicu.a \
    $SKIA/out/linux/libharfbuzz.a $SKIA/out/linux/libfreetype2.a \
    $SKIA/out/linux/libpng.a $SKIA/out/linux/libzlib.a \
    -L$SDL -lSDL3 -lEGL -lGL -lvulkan -lpthread -ldl -lm \
    -femit-bin=$OUT/gallery
echo "==> $OUT/gallery"
