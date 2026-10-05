#!/usr/bin/env bash
# Build Skia natif Linux x86_64 au pin — Graphite Vulkan + Ganesh GL + raster.
set -euo pipefail
SPIKE=/home/ubuntu/work/Klaxon/spikes/k0-linux
SKIA=/home/ubuntu/work/Klaxon/spikes/w0-graphite-wasm/deps/skia   # même checkout que W0
cd "$SKIA"

mkdir -p out/linux
cat > out/linux/args.gn <<'EOF'
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "x64"
target_os = "linux"
cc = "clang"
cxx = "clang++"

skia_use_icu = true
skia_use_client_icu = false
skia_use_icu4x = false
skia_use_libgrapheme = false
skia_use_system_icu = false
skia_use_harfbuzz = true
skia_use_system_harfbuzz = false
skia_use_freetype = true
skia_use_system_freetype2 = false
skia_use_libpng = true
skia_use_system_libpng = false
skia_use_zlib = true
skia_use_system_zlib = false
skia_use_libjpeg_turbo = false
skia_use_libjpeg_turbo_decode = false
skia_use_libjpeg_turbo_encode = false
skia_use_dng_sdk = false
skia_use_libwebp = false
skia_use_libwebp_decode = false
skia_use_libwebp_encode = false
skia_use_no_webp_encode = true
skia_use_wuffs = false
skia_use_expat = false
skia_use_fontconfig = false
skia_use_partition_alloc = false

skia_use_gl = true
skia_use_egl = true
skia_use_x11 = false
skia_use_vulkan = true
skia_use_dawn = false
skia_use_metal = false
skia_use_direct3d = false

skia_enable_ganesh = true
skia_enable_graphite = true
skia_enable_skottie = false
skia_enable_skshaper = true
skia_enable_skparagraph = true
skia_enable_pdf = false
skia_enable_tools = false
skia_use_vma = true

extra_cflags = [ "-Wno-error" ]
extra_cflags_cc = [ "-Wno-error" ]
EOF

./bin/gn gen out/linux
third_party/ninja/ninja -C out/linux skia \
    modules/skparagraph:skparagraph modules/skshaper:skshaper -k 10 \
    2>&1 | tee "$SPIKE/build_skia_linux.log" | tail -3
ls -la out/linux/*.a | awk '{print $5, $9}'
