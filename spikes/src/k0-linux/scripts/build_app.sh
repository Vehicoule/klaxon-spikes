#!/usr/bin/env bash
# Compile le shim natif + kx_scenes + driver et link contre out/linux/*.a
set -euo pipefail
SPIKE=/home/ubuntu/work/Klaxon/spikes/k0-linux
SKIA=/home/ubuntu/work/Klaxon/spikes/w0-graphite-wasm/deps/skia
OUT=$SPIKE/out/app
mkdir -p "$OUT"
cd "$SPIKE"

INC="-I$SKIA -I$SKIA/include -I$SKIA/modules/skunicode/include \
     -I$SKIA/third_party/externals/freetype/include \
     -I$SKIA/third_party/externals/harfbuzz/src \
     -I$SKIA/third_party/externals/icu/source/common \
     -I$SKIA/third_party/externals/vulkanmemoryallocator/include \
     -I$SKIA/third_party/externals/vulkan-headers/include"
FLAGS="-std=c++20 -O2 -fno-exceptions -fno-rtti -DSK_GANESH -DSK_GRAPHITE -DNDEBUG"

for f in shim/kx_skia_linux.cpp shim/kx_scenes.cpp app/main.cpp; do
    o="$OUT/$(basename ${f%.cpp}).o"
    [ "$o" -nt "$f" ] || clang++ $FLAGS $INC -c "$f" -o "$o"
done

LIBS=$(ls $SKIA/out/linux/*.a | tr '\n' ' ')
clang++ -O2 -o $OUT/k0 \
    $OUT/kx_skia_linux.o $OUT/kx_scenes.o $OUT/main.o \
    $LIBS \
    -lEGL -lGL -lvulkan -lpthread -ldl -lm
echo "==> $OUT/k0"
ls -la $OUT/k0
