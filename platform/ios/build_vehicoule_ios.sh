#!/usr/bin/env bash
# build_vehicoule_ios.sh — V1 poche : la vraie app Vehicoule sur iOS-sim.
# zig build-obj aarch64-ios-simulator + shim kx_skia iOS + décodeurs vendored
# (dr_libs + stb_vorbis + opusfile/libopus/libogg pur-C) + kx_media_ios.mm
# (MPNowPlayingInfoCenter) + SDL3.framework + Skia ios-sim → Vehicoule.app
# installée dans le simulateur booté. WAMR absent du build (scan natif).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
K0="$HOME/work/k0-ios"
SKIA="$K0/deps/skia"
OUT="$SKIA/out/ios-simulator"
BIN="$ROOT/bin-ios"
SDLFW="$HOME/work/k2-prep"           # SDL3.framework
SDLINC="$HOME/work/k1-ios/deps/SDL3-3.2.16/include"
ZIG="$HOME/work/zig/zig"
SDK=$(xcrun -sdk iphonesimulator --show-sdk-path)
TARGET="arm64-apple-ios16.0-simulator"
BID="com.vehicoule.player"
APPBUNDLE="$ROOT/Vehicoule.app"
V="$ROOT/vehicoule/vendor"

mkdir -p "$BIN" "$ROOT/results-ios"
CC="xcrun -sdk iphonesimulator clang"
CXX="xcrun -sdk iphonesimulator clang++"
# -DNDEBUG OBLIGATOIRE (SK_DEBUG sinon → layouts SkRefCnt divergents vs
# libskia.a is_debug=false → crash fRefCnt==0 — cf. k3-ios.md).
CXXFLAGS="-target $TARGET -isysroot $SDK -fobjc-arc -std=c++20 -stdlib=libc++ \
  -O2 -g -DNDEBUG -fno-exceptions -fno-rtti -DSKIA_IMPLEMENTATION=0 \
  -I$SKIA -I$ROOT/kx_skia/include -I$ROOT/kx_skia/src -I$SDLINC \
  -I$SKIA/third_party/externals/freetype/include \
  -I$SKIA/third_party/externals/partition_alloc/src \
  -F$SDLFW"
CFLAGS="-target $TARGET -isysroot $SDK -O2 -g -DNDEBUG"

echo "== zig build-obj vehicoule (aarch64-ios-simulator ReleaseFast) =="
"$ZIG" build-obj \
  --dep klaxon --dep ph_runtime \
  -target aarch64-ios-simulator -O ReleaseFast -Mroot="$ROOT/vehicoule/main.zig" \
  -target aarch64-ios-simulator -O ReleaseFast -Mklaxon="$ROOT/klaxon/src/klaxon.zig" \
  -target aarch64-ios-simulator -O ReleaseFast -Mph_runtime="$ROOT/pluginhost/src/runtime.zig" \
  -femit-bin="$BIN/vehicoule.o"
for i in 1 2 3 4 5; do
  nm "$BIN/vehicoule.o" 2>/dev/null | grep -qw "_main" && break
  [ "$i" = 5 ] && { echo "FAIL: _main absent"; exit 1; }
  sleep 1   # APFS : le .o peut arriver en visibilité après la fin de zig
done
nm -u "$BIN/vehicoule.o" | grep -q "_SDL_RunApp" || { echo "FAIL: _SDL_RunApp non référencé"; exit 1; }
nm -u "$BIN/vehicoule.o" | grep -q "wasm_runtime" \
  && { echo "FAIL: symboles WAMR référencés (gate is_mobile cassé)"; exit 1; } || true

echo "== compile shim iOS =="
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_skia_ios.cpp" -o "$BIN/kx_skia_ios.o"
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_draw.cpp"     -o "$BIN/kx_draw.o"
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_scenes.cpp"   -o "$BIN/kx_scenes.o"
$CXX $CXXFLAGS -fno-objc-arc -c "$ROOT/kx_skia/src/kx_metal.mm" -o "$BIN/kx_metal.o"
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_a11y_ios.mm"  -o "$BIN/kx_a11y_ios.o"

echo "== compile MediaSession iOS (MPNowPlayingInfoCenter) =="
$CXX $CXXFLAGS -c "$ROOT/platform/ios/kx_media_ios.mm" -o "$BIN/kx_media_ios.o"

echo "== compile décodeurs vendored (dr_libs/stb/ogg/opusfile/libopus) =="
OPINC="-I$V/opus/include -I$V/opus/celt -I$V/opus/silk -I$V/opus/silk/float -I$V/opus/src"
OFINC="-I$V/ogg/include -I$V/opusfile/include $OPINC"
OPDEF="-DOPUS_BUILD -DUSE_ALLOCA -DHAVE_ALLOCA_H -DHAVE_LRINT -DHAVE_LRINTF -DHAVE_LROUND -DVAR_ARRAYS"
OBJS=""
cc_obj() {
    local s="$1"; shift
    local o="$BIN/$(basename "${s%.*}")_$(echo "$s" | md5 | cut -c1-6).o"
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
        $CC $CFLAGS "$@" -c "$s" -o "$o"
    fi
    OBJS="$OBJS $o"
}
cc_obj "$ROOT/vehicoule/decoder.c" $OFINC
cc_obj "$V/stb_vorbis.c"
cc_obj "$V/ogg/src/bitwise.c" -I$V/ogg/include
cc_obj "$V/ogg/src/framing.c" -I$V/ogg/include
for s in "$V"/opusfile/src/*.c; do cc_obj "$s" $OFINC; done
for s in "$V"/opus/celt/*.c "$V"/opus/silk/*.c "$V"/opus/silk/float/*.c; do
    case "$(basename "$s")" in *_demo.c) continue;; esac
    cc_obj "$s" $OPDEF $OPINC
done
for s in "$V"/opus/src/*.c; do
    case "$(basename "$s")" in *_demo.c|opus_compare.c) continue;; esac
    cc_obj "$s" $OPDEF $OPINC
done
echo "   $(echo $OBJS | wc -w) objets décodeurs"

echo "== link Vehicoule =="
$CXX -target $TARGET -isysroot "$SDK" -fobjc-arc -stdlib=libc++ \
  "$BIN/vehicoule.o" "$BIN/kx_skia_ios.o" "$BIN/kx_draw.o" "$BIN/kx_scenes.o" \
  "$BIN/kx_metal.o" "$BIN/kx_a11y_ios.o" "$BIN/kx_media_ios.o" \
  $OBJS \
  "$OUT/libskia.a" "$OUT/libskparagraph.a" "$OUT/libskshaper.a" \
  "$OUT/libskunicode_icu.a" "$OUT/libskunicode_core.a" "$OUT/libicu.a" \
  "$OUT/libharfbuzz.a" "$OUT/libfreetype2.a" "$OUT/libpng.a" "$OUT/libzlib.a" \
  "$OUT/libskcms.a" "$OUT/libexpat.a" "$OUT/libraw_ptr.a" \
  "$OUT/liballocator_base.a" "$OUT/liballocator_core.a" "$OUT/liballocator_shim.a" \
  -F$SDLFW -framework SDL3 -rpath @executable_path/Frameworks \
  -framework Metal -framework QuartzCore -framework Foundation -framework UIKit \
  -framework CoreText -framework CoreGraphics -framework ImageIO \
  -framework MobileCoreServices -framework MediaPlayer -framework AVFoundation \
  -framework AudioToolbox -framework CoreAudio \
  -o "$BIN/Vehicoule"
ls -la "$BIN/Vehicoule"

echo "== bundle Vehicoule.app (+SDL3.framework +music-test) =="
rm -rf "$APPBUNDLE"; mkdir -p "$APPBUNDLE/Frameworks"
cp "$BIN/Vehicoule" "$APPBUNDLE/Vehicoule"
cp -a "$SDLFW/SDL3.framework" "$APPBUNDLE/Frameworks/"
cp -R "$ROOT/vehicoule/music-test" "$APPBUNDLE/music-test"
cat > "$APPBUNDLE/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.vehicoule.player</string>
  <key>CFBundleName</key><string>Vehicoule</string>
  <key>CFBundleExecutable</key><string>Vehicoule</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string>
         <string>UIInterfaceOrientationLandscapeLeft</string>
         <string>UIInterfaceOrientationLandscapeRight</string></array>
  <key>UIBackgroundModes</key><array><string>audio</string></array>
</dict>
</plist>
EOF

echo "== install dans le simulateur booté =="
DEV=$(xcrun simctl list devices booted | grep -o '([0-9A-F-]*' | tr -d '(' | head -1)
[ -n "$DEV" ] || { echo "aucun simulateur booté"; exit 1; }
xcrun simctl uninstall "$DEV" "$BID" 2>/dev/null || true
xcrun simctl install "$DEV" "$APPBUNDLE"
echo "OK — installé sur $DEV. Lancement :"
echo "  xcrun simctl launch $DEV $BID"
echo "  (config via env : SIMCTL_CHILD_KX_AUTOPLAY=1 SIMCTL_CHILD_KX_SECS=20 \\"
echo "   SIMCTL_CHILD_KX_MUSIC_DIR=<path absolu si non-bundle>)"
