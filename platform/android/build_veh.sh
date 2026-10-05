#!/bin/bash
# build_veh.sh — compile vehicoule (zig 0.17, x86_64-linux-android) + APK gradle.
# V1 poche : scan natif (pas de WAMR-NDK). Décodeurs vendored compilés en cmake.
#
# Staging (depuis le repo Klaxon, à faire une fois) :
#   cp -r vehicoule               $PROJ/app/jni/src/veh
#   mkdir -p $PROJ/app/jni/src/zig/{vehicoule,klaxon,ph}
#   cp vehicoule/main.zig         $PROJ/app/jni/src/zig/vehicoule/
#   cp vehicoule/DejaVuSans.ttf   $PROJ/app/jni/src/zig/vehicoule/
#   cp klaxon/src/*.zig           $PROJ/app/jni/src/zig/klaxon/
#   cp pluginhost/src/runtime.zig $PROJ/app/jni/src/ph/          # (ph_runtime module)
#   cp platform/android/jni/*.cpp $PROJ/app/jni/src/
#   cp platform/android/CMakeLists-vehicoule.txt $PROJ/app/jni/src/CMakeLists.txt
# puis : scripts/build_veh.sh && apksigner sign (keystore local sideload)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJ=android-project
SRC="$PROJ/app/jni/src"
ZIG="${ZIG:-$HOME/kx/tools/zig-x86_64-linux-0.17.0/zig}"
export KX_SKIA_OUT="${KX_SKIA_OUT:-$HOME/kx/deps/skia/out/android-x64}"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# ReleaseSmall pour le shipping (objet 1,2 Mo vs 6,7 en ReleaseFast —
# BUILD-PROFILE.md) ; VEH_OPT=ReleaseFast pour les builds de bench.
VEH_OPT="${VEH_OPT:-ReleaseSmall}"
echo "[zig] vehicoule/main.zig -> vehicoule.o (x86_64-linux-android.31, $VEH_OPT)"
"$ZIG" build-obj -O "$VEH_OPT" -fPIC -lc -fno-stack-check \
    -target x86_64-linux-android.31 \
    --dep klaxon --dep ph_runtime \
    -Mroot="$SRC/zig/vehicoule/main.zig" \
    -Mklaxon="$SRC/zig/klaxon/klaxon.zig" \
    -Mph_runtime="$SRC/ph/runtime.zig" \
    --name vehicoule \
    -femit-bin="$SRC/vehicoule.o" 2>&1 | sed 's/^/[zig] /'
ls -la "$SRC/vehicoule.o"

echo "[gradle] assembleDebug (KX_SKIA_OUT=$KX_SKIA_OUT)"
cd "$PROJ"
./gradlew -PBUILD_WITH_CMAKE :app:assembleDebug --console=plain -q 2>&1 | tail -25
ls -la app/build/outputs/apk/debug/app-debug.apk
