#!/usr/bin/env bash
# build_gallery_ios.sh — K3-parité iOS : build la vraie gallery (zig 0.17,
# a64-ios-simulator) + shim canonique (kx_skia_ios.cpp + kx_draw.cpp +
# kx_scenes.cpp + kx_metal.mm), linke SDL3.framework + libs Skia K0
# (out/ios-simulator), assemble KxGallery.app, installe dans le simulateur booté.
#
# Prérequis : K0 (~/work/k0-ios deps skia ios-simulator), SDL3.framework
# (~/work/k2-prep/SDL3.framework, copie durable du build xcodebuild Release-
# iphonesimulator), zig 0.17 (~/work/zig/zig, avec le patch stdlib
# Io/Threaded.zig NullFile fd pour iOS — voir k3-ios.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K0="$HOME/work/k0-ios"
SKIA="$K0/deps/skia"
OUT="$SKIA/out/ios-simulator"
BIN="$ROOT/bin"
SDLFW="$HOME/work/k2-prep"           # contient SDL3.framework
SDLINC="$HOME/work/k1-ios/deps/SDL3-3.2.16/include"
ZIG="$HOME/work/zig/zig"
SDK=$(xcrun -sdk iphonesimulator --show-sdk-path)
TARGET="arm64-apple-ios16.0-simulator"
BID="com.klaxon.kxgallery"
APPBUNDLE="$ROOT/KxGallery.app"

mkdir -p "$BIN" "$ROOT/results"
CXX="xcrun -sdk iphonesimulator clang++"
# -DNDEBUG OBLIGATOIRE : SkLoadUserConfig.h définit SK_DEBUG si NDEBUG absent →
# nos TU auraient les destructeurs SkRefCnt avec asserts+reset debug alors que
# libskia.a (is_debug=false) unref sans le reset → ~KxStyleSet cross-TU voit
# fRefCnt==0 → abort. Les flags doivent être alignés avec la lib.
CXXFLAGS="-target $TARGET -isysroot $SDK -fobjc-arc -std=c++20 -stdlib=libc++ \
  -O2 -g -DNDEBUG -fno-exceptions -fno-rtti -DSKIA_IMPLEMENTATION=0 \
  -I$SKIA -I$ROOT/kx_skia/include -I$ROOT/kx_skia/src -I$SDLINC \
  -I$SKIA/third_party/externals/freetype/include \
  -I$SKIA/third_party/externals/partition_alloc/src \
  -F$SDLFW"

echo "== zig build-obj gallery (aarch64-ios-simulator ReleaseFast) =="
# ORDRE IMPORTANT : -target/-O précèdent le -M auquel ils s'appliquent
# (per-module settings reset après chaque -M — zig 0.17).
"$ZIG" build-obj \
  --dep klaxon -target aarch64-ios-simulator -O ReleaseFast -Mroot="$ROOT/gallery/main.zig" \
  -target aarch64-ios-simulator -O ReleaseFast -Mklaxon="$ROOT/klaxon/src/klaxon.zig" \
  -femit-bin="$BIN/gallery.o"
nm "$BIN/gallery.o" | grep -qw "_main" || { echo "FAIL: _main absent"; exit 1; }
nm -u "$BIN/gallery.o" | grep -q "_SDL_RunApp" || { echo "FAIL: _SDL_RunApp non référencé (branche iOS éliminée ?)"; exit 1; }
otool -l "$BIN/gallery.o" | grep -A3 LC_BUILD_VERSION | grep -q "platform 7" \
  || { echo "FAIL: platform != IOSSIMULATOR"; exit 1; }

echo "== compile shim (ios-simulator arm64) =="
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_skia_ios.cpp" -o "$BIN/kx_skia_ios.o"
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_draw.cpp"     -o "$BIN/kx_draw.o"
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_scenes.cpp"   -o "$BIN/kx_scenes.o"
$CXX $CXXFLAGS -fno-objc-arc -c "$ROOT/kx_skia/src/kx_metal.mm" -o "$BIN/kx_metal.o"
# bridge UIAccessibility (ARC ok — pas de CF manuel)
$CXX $CXXFLAGS -c "$ROOT/kx_skia/src/kx_a11y_ios.mm" -o "$BIN/kx_a11y_ios.o"

echo "== link KxGallery =="
$CXX -target $TARGET -isysroot "$SDK" -fobjc-arc -stdlib=libc++ \
  "$BIN/gallery.o" "$BIN/kx_skia_ios.o" "$BIN/kx_draw.o" "$BIN/kx_scenes.o" "$BIN/kx_metal.o" "$BIN/kx_a11y_ios.o" \
  "$OUT/libskia.a" "$OUT/libskparagraph.a" "$OUT/libskshaper.a" \
  "$OUT/libskunicode_icu.a" "$OUT/libskunicode_core.a" "$OUT/libicu.a" \
  "$OUT/libharfbuzz.a" "$OUT/libfreetype2.a" "$OUT/libpng.a" "$OUT/libzlib.a" \
  "$OUT/libskcms.a" "$OUT/libexpat.a" "$OUT/libraw_ptr.a" \
  "$OUT/liballocator_base.a" "$OUT/liballocator_core.a" "$OUT/liballocator_shim.a" \
  -F$SDLFW -framework SDL3 -rpath @executable_path/Frameworks \
  -framework Metal -framework QuartzCore -framework Foundation -framework UIKit \
  -framework CoreText -framework CoreGraphics -framework ImageIO \
  -framework MobileCoreServices \
  -o "$BIN/KxGallery"
ls -la "$BIN/KxGallery"

echo "== bundle .app (+SDL3.framework embarqué) =="
rm -rf "$APPBUNDLE"; mkdir -p "$APPBUNDLE/Frameworks"
cp "$BIN/KxGallery" "$APPBUNDLE/KxGallery"
cp -a "$SDLFW/SDL3.framework" "$APPBUNDLE/Frameworks/"
cat > "$APPBUNDLE/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleIdentifier</key><string>com.klaxon.kxgallery</string>
 <key>CFBundleExecutable</key><string>KxGallery</string>
 <key>CFBundleName</key><string>KxGallery</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleVersion</key><string>1</string>
 <key>CFBundleShortVersionString</key><string>1.0</string>
 <key>MinimumOSVersion</key><string>16.0</string>
 <key>LSRequiresIPhoneOS</key><true/>
 <key>UILaunchStoryboardName</key><string></string>
 <key>UISupportedInterfaceOrientations</key><array>
   <string>UIInterfaceOrientationPortrait</string>
   <string>UIInterfaceOrientationLandscapeLeft</string>
   <string>UIInterfaceOrientationLandscapeRight</string>
 </array>
 <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
 <key>UILaunchScreen</key><dict/></dict></plist>
EOF
codesign --sign - --force --timestamp=none "$APPBUNDLE/Frameworks/SDL3.framework" 2>&1 | tail -1 || true
codesign --sign - --force --timestamp=none "$APPBUNDLE" 2>&1 | tail -1 || true

echo "== install (simulateur booté) =="
xcrun simctl terminate booted "$BID" 2>/dev/null || true
xcrun simctl install booted "$APPBUNDLE"
echo "[script] installé — lance avec : xcrun simctl launch --console-pty booted $BID [args]"
