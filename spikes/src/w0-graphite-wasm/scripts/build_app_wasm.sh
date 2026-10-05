#!/usr/bin/env bash
# build_app_wasm.sh — compile le shim C++ + main.zig et linke en w0.{js,wasm}.
set -euo pipefail
cd "$(dirname "$0")/.."

EM=/home/ubuntu/tools/emsdk/upstream/emscripten/em++
ZIG=/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig
SK=deps/skia
PKG=build/emdawnwebgpu_pkg
OUT=out/app
mkdir -p "$OUT"

FLAGS="-DNDEBUG -DSK_TRIVIAL_ABI=[[clang::trivial_abi]] -DSK_GANESH -DSK_GRAPHITE \
 -DSK_GAMMA_APPLY_TO_A8 -DSK_DAWN -DSKIA_IMPLEMENTATION=1 -DSK_TYPEFACE_FACTORY_FREETYPE \
 -I$SK -I$SK/include -I$SK/modules/skparagraph/include -I$SK/modules/skunicode/include \
 -I$SK/third_party/externals/partition_alloc/src -Wno-attributes -ffp-contract=off -fPIC \
 -fvisibility=hidden -fvisibility-inlines-hidden -std=c++20 -fno-exceptions -fno-rtti -O3 \
 -isystem $PKG/webgpu/include -isystem $PKG/webgpu_cpp/include -I shim"

for f in kx_skia kx_scenes kx_draw; do
    [ -f "$OUT/$f.o" ] && [ "shim/$f.cpp" -ot "$OUT/$f.o" ] || \
        $EM $FLAGS -c "shim/$f.cpp" -o "$OUT/$f.o"
done

# Zig → objet wasm32-emscripten
$ZIG build-obj -target wasm32-emscripten -OReleaseSmall app/main.zig \
    -femit-bin="$OUT/main_zig.o" 2>&1 | grep -v "^$" || true

LIBS="$SK/out/wasm/libskia.a $SK/out/wasm/libskparagraph.a $SK/out/wasm/libskshaper.a \
 $SK/out/wasm/libskunicode_icu.a $SK/out/wasm/libskunicode_core.a $SK/out/wasm/libicu.a \
 $SK/out/wasm/libharfbuzz.a $SK/out/wasm/libfreetype2.a $SK/out/wasm/libpng.a \
 $SK/out/wasm/libzlib.a $SK/out/wasm/libskcms.a $SK/out/wasm/libraw_ptr.a \
 $SK/out/wasm/liballocator_core.a $SK/out/wasm/liballocator_base.a \
 $SK/out/wasm/liballocator_shim.a"

$EM $FLAGS -o app/w0.js \
    "$OUT/kx_skia.o" "$OUT/kx_scenes.o" "$OUT/kx_draw.o" "$OUT/main_zig.o" $LIBS \
    --use-port="$PKG/emdawnwebgpu.port.py" \
    -sUSE_WEBGL2=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2gb \
    -sEXPORTED_FUNCTIONS=_main,_kx_start,_kx_step,_kx_poll_readback,_kx_alloc,_kx_add_font,_kx_free_alloc,_kx_fonts_add,_kx_fonts_global,_malloc,_free \
    -sEXPORTED_RUNTIME_METHODS=UTF8ToString,HEAPU8 \
    --js-library app/library_kx.js \
    --pre-js app/app.js \
    -sMODULARIZE=0 -sASSERTIONS=1 -sSTACK_SIZE=4mb

echo "==> app/w0.js + app/w0.wasm"
ls -la app/w0.* 2>/dev/null | awk '{print $5, $9}'
