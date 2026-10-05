#!/usr/bin/env bash
# Reproducible Skia wasm build for the W0 spike.
# Builds libskia.a + libskparagraph.a + libskshaper.a + libskunicode.a
# with Graphite(WebGPU/emdawnwebgpu) + Ganesh(WebGL2) + raster.
set -euo pipefail
SPIKE=/home/ubuntu/work/Klaxon/spikes/w0-graphite-wasm
SKIA=$SPIKE/deps/skia
PKG=$SPIKE/build/emdawnwebgpu_pkg
export PATH=/home/ubuntu/tools/depot_tools:/home/ubuntu/tools/emsdk:/home/ubuntu/tools/emsdk/upstream/emscripten:/home/ubuntu/tools/emsdk/node/24.19.0_64bit/bin:$PATH

cd "$SKIA"

# --- apply patches ---
for p in "$SPIKE"/patches/*.patch; do
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p" && echo "applied $(basename "$p")"
  elif git apply --check --reverse "$p" 2>/dev/null; then
    echo "$(basename "$p") already applied"
  else
    echo "FATAL: $(basename "$p") applies neither forward nor reverse"; exit 1
  fi
done

mkdir -p out/wasm
cat > out/wasm/args.gn <<EOF
is_debug = false
is_official_build = true
is_component_build = false
is_trivial_abi = true
is_canvaskit = true
werror = false
target_cpu = "wasm"
skia_emsdk_dir = "/home/ubuntu/tools/emsdk"
cc = "/home/ubuntu/tools/emsdk/upstream/emscripten/emcc"
cxx = "/home/ubuntu/tools/emsdk/upstream/emscripten/em++"
ar = "/home/ubuntu/tools/emsdk/upstream/emscripten/emar"
skia_use_angle = false
skia_use_dng_sdk = false
skia_use_dawn = true
skia_use_webgl = true
skia_use_webgpu = true
skia_use_expat = false
skia_use_fontconfig = false
skia_use_freetype = true
skia_use_freetype_woff2 = false
skia_enable_fontmgr_custom_directory = false
skia_enable_fontmgr_custom_empty = true
skia_enable_fontmgr_custom_embedded = false
skia_use_libjpeg_turbo_decode = false
skia_use_libjpeg_turbo_encode = false
skia_use_libpng_decode = true
skia_use_libpng_encode = true
skia_use_libwebp_decode = false
skia_use_libwebp_encode = false
skia_use_lua = false
skia_use_piex = false
skia_use_system_freetype2 = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = false
skia_use_wuffs = false
skia_use_zlib = true
skia_use_icu = true
skia_use_client_icu = false
skia_use_icu4x = false
skia_use_libgrapheme = false
skia_use_system_icu = false
skia_use_harfbuzz = true
skia_use_system_harfbuzz = false
skia_enable_ganesh = true
skia_enable_graphite = true
skia_enable_skottie = false
skia_enable_skshaper = true
skia_enable_skparagraph = true
skia_enable_pdf = false
skia_enable_tools = false
extra_cflags = [
  "-isystem", "$PKG/webgpu/include",
]
extra_cflags_cc = [
  "-isystem", "$PKG/webgpu/include",
  "-isystem", "$PKG/webgpu_cpp/include",
]
EOF

./bin/gn gen out/wasm
third_party/ninja/ninja -C out/wasm skia modules/skparagraph:skparagraph modules/skshaper:skshaper -k 10
ls -la out/wasm/*.a out/wasm/obj/modules/**/*.a 2>/dev/null || find out/wasm -name "*.a" | head -20
