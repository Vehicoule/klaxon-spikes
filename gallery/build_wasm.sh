#!/usr/bin/env bash
# build_wasm.sh — gallery Klaxon pour le web : Zig→wasm32-emscripten +
# shim kx_skia (Ganesh-WebGL2 sur #canvas) + SDL3-emscripten + Skia wasm.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
EM=/home/ubuntu/tools/emsdk/upstream/emscripten/em++
ZIG=/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig
SK=spikes/w0-graphite-wasm/deps/skia
PKG=spikes/w0-graphite-wasm/build/emdawnwebgpu_pkg
SHIM=spikes/w0-graphite-wasm/shim
SDL=spikes/k1-sdl/deps/SDL3-wasm-build/libSDL3.a
OUT=gallery/out/wasm
mkdir -p "$OUT"

FLAGS="-DNDEBUG -DSK_TRIVIAL_ABI=[[clang::trivial_abi]] -DSK_GANESH -DSK_GRAPHITE \
 -DSK_GAMMA_APPLY_TO_A8 -DSK_DAWN -DSKIA_IMPLEMENTATION=1 -DSK_TYPEFACE_FACTORY_FREETYPE \
 -I$SK -I$SK/include -I$SK/modules/skparagraph/include -I$SK/modules/skunicode/include \
 -I$SK/third_party/externals/partition_alloc/src -Wno-attributes -ffp-contract=off -fPIC \
 -fvisibility=hidden -fvisibility-inlines-hidden -std=c++20 -fno-exceptions -fno-rtti -O3 \
 -isystem $PKG/webgpu/include -isystem $PKG/webgpu_cpp/include -I $SHIM"

# 1) shim C++ (wasm) — kx_skia.cpp + kx_draw.cpp (Ganesh-WebGL2 + raster)
for f in kx_skia kx_draw; do
    [ -f "$OUT/$f.o" ] && [ "$SHIM/$f.cpp" -ot "$OUT/$f.o" ] || \
        $EM $FLAGS -c "$SHIM/$f.cpp" -o "$OUT/$f.o"
done

# 2) Zig : main + module klaxon → objet wasm32-emscripten
$ZIG build-obj -target wasm32-emscripten -OReleaseSmall \
    --dep klaxon -Mroot=gallery/main.zig -Mklaxon=klaxon/src/klaxon.zig \
    -femit-bin="$OUT/main_zig.o"

LIBS="$SK/out/wasm/libskia.a $SK/out/wasm/libskparagraph.a $SK/out/wasm/libskshaper.a \
 $SK/out/wasm/libskunicode_icu.a $SK/out/wasm/libskunicode_core.a $SK/out/wasm/libicu.a \
 $SK/out/wasm/libharfbuzz.a $SK/out/wasm/libfreetype2.a $SK/out/wasm/libpng.a \
 $SK/out/wasm/libzlib.a $SK/out/wasm/libskcms.a $SK/out/wasm/libraw_ptr.a \
 $SK/out/wasm/liballocator_core.a $SK/out/wasm/liballocator_base.a \
 $SK/out/wasm/liballocator_shim.a"

# 3) link → gallery.js + gallery.wasm
$EM -o gallery/out/wasm/gallery.js \
    "$OUT/main_zig.o" "$OUT/kx_skia.o" "$OUT/kx_draw.o" $SDL $LIBS \
    --use-port="$PKG/emdawnwebgpu.port.py" \
    -sUSE_WEBGL2=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2gb \
    -sEXPORTED_FUNCTIONS=_main,_gallery_init,_gallery_step,_gallery_kick,_gallery_target_ok,_gallery_backend,_gallery_semantics_sync,_gallery_semantics_ptr,_gallery_semantics_len,_gallery_tap \
    -sMODULARIZE=0 -sASSERTIONS=1 -sSTACK_SIZE=4mb -sEXIT_RUNTIME=0

echo "==> gallery/out/wasm/gallery.js + gallery.wasm"
ls -la gallery/out/wasm/gallery.* 2>/dev/null | awk '{print $5, $9}'
